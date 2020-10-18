#!/bin/bash
#
# Test script for libdeflate

set -eu -o pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 0 ]; then
	echo 1>&2 "Usage: $0"
	exit 2
fi

if [ -z "${TESTDATA:-}" ]; then
	# Generate default TESTDATA file.
	TESTDATA=$(mktemp -t libdeflate_testdata.XXXXXXXXXX)
	trap 'rm -f "$TESTDATA"' EXIT
	cat $(find . -name '*.c' -o -name '*.h' -o -name '*.sh') \
		| head -c 1000000 > "$TESTDATA"
fi

NPROC=$(grep -c processor /proc/cpuinfo)
VALGRIND="valgrind --quiet --error-exitcode=100 --leak-check=full --errors-for-leak-kinds=all"
SANITIZE_CFLAGS="-fsanitize=undefined -fno-sanitize-recover=undefined,integer"

###############################################################################

log() {
	echo "[$(date)] $@"
}

run_cmd() {
	log "$@"
	"$@" > /dev/null
}

###############################################################################

native_build_and_test() {

	# Build libdeflate, including the test programs.  Set the special test
	# support flag to get support for LIBDEFLATE_DISABLE_CPU_FEATURES.
	make "$@" TEST_SUPPORT__DO_NOT_USE=1 \
		-j$NPROC all test_programs > /dev/null

	# When not using -march=native, run the tests multiple times with
	# different combinations of CPU features disabled.  This is needed to
	# test all variants of dynamically-dispatched code.
	#
	# For now, we aren't super exhausive in which combinations of features
	# we test disabling.  We just disable the features roughly in order from
	# newest to oldest for each architecture, cumulatively.  In practice,
	# that's good enough to cover all the code.
	local features=('')
	if ! [[ "$*" =~ "-march=native" ]]; then
		case "$(uname -m)" in
		i386|x86_64)
			features+=(avx512bw avx2 avx bmi2 pclmul sse2)
			;;
		arm*|aarch*)
			features+=(crc32 pmull neon)
			;;
		esac
	fi
	local disable_str=""
	local feature
	for feature in "${features[@]}"; do
		if [ -n "$feature" ]; then
			if [ -n "$disable_str" ]; then
				disable_str+=","
			fi
			disable_str+="$feature"
			log "Retrying with CPU features disabled: $disable_str"
		fi
		WRAPPER="$WRAPPER" TESTDATA="$TESTDATA" \
			LIBDEFLATE_DISABLE_CPU_FEATURES="$disable_str" \
			sh ./scripts/exec_tests.sh > /dev/null
	done
}

native_tests() {
	local compiler compilers_to_try=(gcc)
	local cflags cflags_to_try=("")
	shopt -s nullglob
	compilers_to_try+=(/usr/bin/gcc-[0-9]*)
	compilers_to_try+=(/usr/bin/clang-[0-9]*)
	compilers_to_try+=(/opt/gcc*/bin/gcc)
	compilers_to_try+=(/opt/clang*/bin/clang)
	shopt -u nullglob

	if [ "$(uname -m)" = "x86_64" ]; then
		cflags_to_try+=("-march=native")
		cflags_to_try+=("-m32")
	fi
	for compiler in ${compilers_to_try[@]}; do
		for cflags in "${cflags_to_try[@]}"; do
			if [ "$cflags" = "-m32" ] && \
			   $compiler -v |& grep -q -- '--disable-multilib'
			then
				continue
			fi
			log "Running tests with CC=$compiler," \
				"CFLAGS=$cflags"
			WRAPPER= native_build_and_test \
				CC=$compiler CFLAGS="$cflags -Werror"
		done
	done

	log "Running tests with Valgrind"
	WRAPPER="$VALGRIND" native_build_and_test

	log "Running tests with undefined behavior sanitizer"
	WRAPPER= native_build_and_test CC=clang CFLAGS="$SANITIZE_CFLAGS"
}

# Test the library built with FREESTANDING=1.
freestanding_tests() {

	WRAPPER= native_build_and_test FREESTANDING=1
	if nm libdeflate.so | grep -q ' U '; then
		echo 1>&2 "Freestanding lib links to external functions!:"
		nm libdeflate.so | grep ' U '
		return 1
	fi
	if ldd libdeflate.so | grep -q -v '\<statically linked\>'; then
		echo 1>&2 "Freestanding lib links to external libraries!:"
		ldd libdeflate.so
		return 1
	fi

	WRAPPER="$VALGRIND" native_build_and_test FREESTANDING=1

	WRAPPER= native_build_and_test FREESTANDING=1 \
		CC=clang CFLAGS="$SANITIZE_CFLAGS"
}

###############################################################################

gzip_tests() {

	local gzip gunzip
	run_cmd make -j$NPROC gzip gunzip
	for gzip in "$PWD/gzip" /bin/gzip; do
		for gunzip in "$PWD/gunzip" /bin/gunzip; do
			log "Running gzip program tests with GZIP=$gzip," \
				"GUNZIP=$gunzip"
			GZIP="$gzip" GUNZIP="$gunzip" TESTDATA="$TESTDATA" \
				./scripts/gzip_tests.sh
		done
	done

	log "Running gzip program tests with Valgrind"
	GZIP="$VALGRIND $PWD/gzip" GUNZIP="$VALGRIND $PWD/gunzip" \
		TESTDATA="$TESTDATA" ./scripts/gzip_tests.sh

	log "Running gzip program tests with undefined behavior sanitizer"
	run_cmd make -j$NPROC CC=clang CFLAGS="$SANITIZE_CFLAGS" gzip gunzip
	GZIP="$PWD/gzip" GUNZIP="$PWD/gunzip" \
		TESTDATA="$TESTDATA" ./scripts/gzip_tests.sh
}

###############################################################################

log "Starting libdeflate tests"
native_tests
freestanding_tests
gzip_tests
log "All tests passed!"
