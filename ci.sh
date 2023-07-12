#!/bin/bash

set -ex -o pipefail

# Log some general info about the environment
uname -a
env | sort

if [ "$JOB_NAME" = "" ]; then
    JOB_NAME="${TRAVIS_OS_NAME}-${TRAVIS_PYTHON_VERSION:-unknown}"
fi

# Curl's built-in retry system is not very robust; it gives up on lots of
# network errors that we want to retry on. Wget might work better, but it's
# not installed on azure pipelines's windows boxes. So... let's try some good
# old-fashioned brute force. (This is also a convenient place to put options
# we always want, like -f to tell curl to give an error if the server sends an
# error response, and -L to follow redirects.)
function curl-harder() {
    for BACKOFF in 0 1 2 4 8 15 15 15 15; do
        sleep $BACKOFF
        if curl -fL --connect-timeout 5 "$@"; then
            return 0
        fi
    done
    return 1
}

################################################################
# We have a Python environment!
################################################################

python -c "import sys, struct, ssl; print('#' * 70); print('python:', sys.version); print('version_info:', sys.version_info); print('bits:', struct.calcsize('P') * 8); print('openssl:', ssl.OPENSSL_VERSION, ssl.OPENSSL_VERSION_INFO); print('#' * 70)"

python -m pip install -U pip setuptools wheel
python -m pip --version

python setup.py sdist --formats=zip
python -m pip install dist/*.zip

# See https://github.com/python-trio/trio/issues/334
YAPF_VERSION=0.20.0

if [ "$CHECK_FORMATTING" = "1" ]; then
    pip install yapf==${YAPF_VERSION}
    if ! yapf -rpd setup.py trio_asyncio; then
        cat <<EOF
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

Formatting problems were found (listed above). To fix them, run

   pip install yapf==${YAPF_VERSION}
   yapf -rpi setup.py trio_asyncio

in your local checkout.

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
        exit 1
    fi
    exit 0
else
    # Actual tests
    python -m pip install -r test-requirements.txt

    # We run the tests from inside an empty directory, to make sure Python
    # doesn't pick up any .py files from our working dir. Might have been
    # pre-created by some of the code above.
    mkdir empty || true
    cd empty

    INSTALLDIR=$(python -c "import os, trio_asyncio; print(os.path.dirname(trio_asyncio.__file__))")
    cp ../pyproject.toml $INSTALLDIR

    # support subprocess spawning with coverage.py
    echo "import coverage; coverage.process_startup()" | tee -a "$INSTALLDIR/../sitecustomize.py"

    if COVERAGE_PROCESS_START=$(pwd)/../.coveragerc coverage run --rcfile=../.coveragerc -m pytest -r a --junitxml=../test-results.xml --verbose ../tests; then
        PASSED=true
    else
        PASSED=false
    fi

    coverage combine --rcfile ../.coveragerc
    coverage report -m --rcfile ../.coveragerc
    coverage xml --rcfile ../.coveragerc

    $PASSED
fi
