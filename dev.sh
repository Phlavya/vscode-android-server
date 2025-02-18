#!/usr/bin/env bash

main() {
  cd "$(dirname "$0")/"

    case "$1" in
      diff)
        cd code-server/lib
        diff -x node_modules -x build -x .build -x 'out-*' -x out -ru vscode.orig vscode
        ;;
      save-diff)
        cd code-server/lib
        diff -x node_modules -x build -x .build -x 'out-*' -x out -ru vscode.orig vscode > ../../vscode.vh.patch
        ;;
      apply-patch)
        if [[ -f ./vscode.vh.patch ]]; then
          cd code-server/lib/vscode && git apply ../../../vscode.vh.patch
        fi
        if [[ -f ./node-src.vh.patch ]]; then
          cd node-src && git apply ../node-src.vh.patch
        fi
        ;;
      build-android-env)
        docker build ./container/android -t vsandroidenv:latest
        ;;
      release)
        if [ "$EUID" -ne 0 ]; then
          USERRUN=
        else
          BUILDING_USER=$(ls -n /vscode/dev.sh | awk '{print $3}')
          BUILDING_GROUP=$(ls -n /vscode/dev.sh | awk '{print $4}')
          if ! grep -q code-builder /etc/passwd; then
            groupadd -g $BUILDING_GROUP builder-gr
            useradd -m -g $BUILDING_GROUP -u $BUILDING_USER -N code-builder 
          fi
          USERRUN="sudo -E -H -u #$BUILDING_USER"
        fi
        set -x

        echo $ANDROID_ARCH > current_building
        gcc -shared -fPIC /vscode-build/lib/node-preload.c -o /vscode-build/lib/node-preload.so -ldl 
        chmod 0744 /vscode-build/lib/node-preload.so
        case $ANDROID_ARCH in
          arm|armeabi-v7a)
            ARCH_NAME="armeabi-v7a"
            NODE_CONFIGURE_NAME="arm"
            TERMUX_ARCH="arm"
          ;;
          x86)
            ARCH_NAME="x86"
            NODE_CONFIGURE_NAME="x86"
            TERMUX_ARCH="i686"
          ;;
          x86_64)
            ARCH_NAME="x86_64"
            NODE_CONFIGURE_NAME="x86_64"
            TERMUX_ARCH="x86_64"
            ;;
          arm64|aarch64)
            ARCH_NAME="arm64-v8a"
            NODE_CONFIGURE_NAME="arm64"
            TERMUX_ARCH="aarch64"
            ;;
          *)
            echo "Unsupported arch $ANDROID_ARCH"
            exit 1
            ;;
        esac
      	set -e
        if [ ! -z "$BUILD_NODE" ]; then
          pushd node-src
          $USERRUN make clean
          git clean -dfX
          git checkout -f HEAD
          git apply ../node-src.vh.patch
          if [[ "$ANDROID_ARCH" == "x86_64" ]]; then
            $USERRUN git checkout HEAD -- ./deps/v8/src/trap-handler/trap-handler.h
            $USERRUN mv ./deps/v8/src/trap-handler/trap-handler.h ./deps/v8/src/trap-handler/trap-handler.h.orig
            cat ./deps/v8/src/trap-handler/trap-handler.h.orig | sed 's/define V8_TRAP_HANDLER_SUPPORTED true/define V8_TRAP_HANDLER_SUPPORTED false/g' | $USERRUN tee ./deps/v8/src/trap-handler/trap-handler.h
          fi
          $USERRUN PATH=/vscode-build/hostbin:$PATH CC_host=gcc CXX_host=g++ LINK_host=g++ ./android-configure /opt/android-ndk/ $NODE_CONFIGURE_NAME $ANDROID_BUILD_API_VERSION
          NODE_MAKE_CUSTOM_LDFLAGS=
          if [[ "$ANDROID_ARCH" == "x86" ]]; then
            NODE_MAKE_CUSTOM_LDFLAGS=-latomic
          fi
          LDFLAGS="$LDFLAGS $NODE_MAKE_CUSTOM_LDFLAGS" PATH=/vscode-build/hostbin:$PATH JOBS=$(nproc) make -j $(nproc)
          if [[ -f "deps/v8/src/trap-handler/trap-handler.h.orig" ]]; then
            $USERRUN mv -f ./deps/v8/src/trap-handler/trap-handler.h.orig ./deps/v8/src/trap-handler/trap-handler.h
          fi
          $USERRUN mkdir -p include/node
          $USERRUN cp config.gypi include/node/config.gypi
          popd
        fi
        for f in /usr/lib/node_modules/npm/bin/node-gyp-bin/node-gyp; do
          if [ ! -f "$f.orig" ]; then
            mv $f "$f.orig"
          fi
          echo -e '#!/bin/bash\n/vscode-build/bin/node-gyp-hook $0 $@\n'$f'.orig --nodedir /vscode/node-src/ "$@"' > $f
          chmod 0747 $f
          chmod 0747 "$f.orig"
        done
        for f in /usr/bin/node; do
          if [ ! -f "$f.orig" ]; then
            mv $f "$f.orig"
          fi
          echo -e '#!/bin/bash\n/vscode-build/bin/node-hook '$f'.orig "$@"' > $f
          chmod 0747 $f
          chmod 0747 "$f.orig"
        done
        YARN="$USERRUN CC_target=cc AR_target=ar CXX_target=cxx LINK_target=ld PATH=/vscode-build/bin:$PATH yarn"
        if [ ! -z "$BUILD_RELEASE" ]; then
          pushd code-server
            yarn cache clean
            $USERRUN yarn cache clean
            sub_builder() {
              find $1 -iname yarn.lock | grep -v node_modules | while IPS= read dir
              do
                echo "$dir"
                pushd "$(dirname "$dir")"
                set -x
                  echo "* Work on $(pwd)"
                  $YARN --frozen-lockfile --production=false
                  [[ "$(jq ".scripts.build" package.json )" != "null" ]] && $YARN build
                  [[ "$(jq ".scripts.release" package.json )" != "null" ]] && $YARN release
                  [[ "$(jq ".scripts[\"release:standalone\"]" package.json )" != "null" ]] && $YARN release:standalone
                  $YARN --frozen-lockfile --production
                set +x
                popd
              done
            }
            rm -rf release release-standalone node_modules
            export NODE_PATH=/usr/lib/node_modules
            npm install -g @mapbox/node-pre-gyp node-addon-api
            $USERRUN mv -f yarn.lock.origbk yarn.lock || true
            $YARN --production=false --frozen-lockfile
            $USERRUN mv -f yarn.lock yarn.lock.origbk || true
            sub_builder .
            $USERRUN mv -f yarn.lock.origbk yarn.lock || true
            sub_builder lib
            pushd lib/vscode
                  $YARN --frozen-lockfile --production=false
            popd
            $YARN build
            $YARN build:vscode
            $YARN release
            #nonexisten proxy to disable downloading
            $YARN release:standalone
            cd release-standalone
            $YARN --production --frozen-lockfile
          popd
        fi
        rm -rf cs-$ANDROID_ARCH.tgz libc++_shared.so node
        cp node-src/out/Release/node ./
        cp /opt/android-ndk/sources/cxx-stl/llvm-libc++/libs/$ARCH_NAME/libc++_shared.so ./libc++_shared.so
        VERSION_SUFFIX=
        if [[ -f patch_version ]]; then
          VERSION_SUFFIX="-p$(cat patch_version)"
        fi
      	echo "$(cat code-server/package.json | jq -r '.version')$VERSION_SUFFIX" | tr -d '\n' | $USERRUN tee code-server/VERSION
        $USERRUN ANDROID_ARCH=$ANDROID_ARCH TERMUX_ARCH=$TERMUX_ARCH bash ./scripts/download-rg.sh
        find code-server/release-standalone -iname rg | while IPS= read p
        do
          echo "Replace rg in $p"
          $USERRUN cp rg/$ANDROID_ARCH/rg $p
          echo md5 $p
        done
        if [[ "$(find code-server/release-standalone -iname '*.orig')" != "" ]]; then
          find code-server/release-standalone -iname '*.orig'
          exit -1
        fi
        $USERRUN tar -czvf cs-$ANDROID_ARCH.tgz code-server/release-standalone code-server/VERSION node "libc++_shared.so"
        find code-server/release-standalone/ -iname '*.node' | grep -v prebui | xargs file
        ;;
      docker-run)
        shift
        set -x
        docker run --rm \
                -w /vscode \
                -e ANDROID_BUILD_API_VERSION=24 \
                -v $(pwd):/vscode \
                -v $(pwd)/container/android:/vscode-build \
                -v $(pwd)/node:/vscode-node \
                -v $(pwd)/.git/modules/code-server:/.git/modules/code-server \
                --entrypoint env \
                vsandroidenv:latest OKOKOKRUN=1 "$@"; exit $?
        ;;
      *)
        docker run --rm -it \
                -w /vscode \
                -e ANDROID_BUILD_API_VERSION=24 \
                -v $(pwd):/vscode \
                -v $(pwd)/container/android:/vscode-build \
                -v $(pwd)/node:/vscode-node \
                -v $(pwd)/.git/modules/code-server:/.git/modules/code-server \
                vsandroidenv:latest bash; exit $?
        ;;
    esac
}

main "$@"

