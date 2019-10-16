#!/bin/bash

if [ -z "$1" ]; then
  echo "usage: $0 <git_server>"
  exit 1
fi

TMPWORKDIR=$(mktemp -d -t k8s_build-XXXXXXX)
repodir="kubernetes"
builddir="$TMPWORKDIR/$repodir"

function cleanup {
  if [ -d "$TMPWORKDIR" ]; then
    cd $TMPWORKDIR
    [[ -d "$repodir" ]] && rm -rf $repodir
    cd ..
    rmdir $TMPWORKDIR
  fi
}

echo "Working directory $builddir"
set -x

git clone git@${1}:kubernetes/kubernetes.git "$builddir"

if [ $? -ne 0 -o ! -d "$builddir" ]; then
    echo "Git clone failed to $builddir"
    exit 1
else
    echo "Clone successful"
fi

pushd "$builddir"
git remote add github https://github.com/kubernetes/kubernetes.git
git fetch github -a
git pull github master
K8S_NIGHTLY=$(curl https://storage.googleapis.com/kubernetes-release-dev/ci-cross/latest.txt)
git reset ${K8S_NIGHTLY#*+}
git push --force --all
git push --tags --force

popd
cleanup
set +x
