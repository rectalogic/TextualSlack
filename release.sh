#!/bin/bash
set -o errexit

TAG=$1
BUILDDIR=$2

if [ -z "$TAG" ] || [ -z "$BUILDDIR" ]; then
    echo "Usage: $0 <git-tag> <build-dir>"
    echo "    <git-tag> should be an existing tag of the form"
    echo "       v<version>-<marketing-version> e.g. v35-3.0.1"
    exit 1
fi
# Need absolute path
BUILDDIR=$(cd "$BUILDDIR"; pwd)
VERSIONSPEC=${TAG#v}
VERSIONSPEC=(${VERSIONSPEC//-/ })
VERSION=${VERSIONSPEC[0]?:No version in tag}
MARKETING_VERSION=${VERSIONSPEC[1]?:No marketing version in tag}

# git archive tag and build from that
PROJECT="$BUILDDIR/TextualSlack-$VERSION"
mkdir -p "$PROJECT"
git archive $TAG | tar -C "$PROJECT" -xf -

(
  cd "$PROJECT"
  agvtool new-version -all $VERSION
  agvtool new-marketing-version $MARKETING_VERSION
  ./build.sh
)
