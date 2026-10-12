{
  lib,
  stdenv,

  fetchFromGitHub,
  fetchYarnDeps,
  replaceVars,
  writeShellScriptBin,

  androidenv,
  clojure,
  gradle_8-unwrapped,
  jdk17,
  nodejs-slim,
  yarnConfigHook,
}:

let
  package = builtins.fromJSON (builtins.readFile ../package.json);

  # Android SDK components needed to compile against SDK level 33
  # (Android 13) as declared in android/variables.gradle.
  androidSdk = androidenv.composeAndroidPackages {
    buildToolsVersions = [
      "33.0.1"
      "33.0.2"
    ];
    platformVersions = [
      "31"
      "33"
    ];
    abiVersions = [
      "armeabi-v7a"
      "arm64-v8a"
    ];
    includeNDK = false;
    includeEmulator = false;
    includeSystemImages = false;
  };

in
stdenv.mkDerivation (finalAttrs: {
  pname = "${package.name}-android";
  version = package.version;

  src = lib.cleanSource ../.;

  # Only the cljs-time/bb-tasks patch applies to the mobile build;
  # the electron-specific patches are deliberately omitted.
  patches = [
    (replaceVars ./patches/hardcode-git-paths.patch {
      cljs_time_src = fetchFromGitHub {
        owner = "logseq";
        repo = "cljs-time";
        rev = "5704fbf48d3478eedcf24d458c8964b3c2fd59a9";
        hash = "sha256-IApL+SEm7AhbTN7J/1KiAKTx7rd53hchRh3jmPQ412g=";
      };
      bb_tasks_src = fetchFromGitHub {
        owner = "logseq";
        repo = "bb-tasks";
        rev = "70d3edeb287f5cec7192e642549a401f7d6d4263";
        hash = "sha256-xVJj5XCkqfaNjnhYZkuqTSJN0ry8UVMaN44r9pxggB0=";
      };
    })
  ];

  # ------------------------------------------------------------------ #
  # Clojure Maven dependencies (identical to the desktop derivation).   #
  # ------------------------------------------------------------------ #
  mavenRepo = stdenv.mkDerivation {
    name = "logseq-md-${finalAttrs.version}-maven-deps";
    inherit (finalAttrs) src patches;

    nativeBuildInputs = [ clojure ];

    buildPhase = ''
      runHook preBuild
      export HOME="$(mktemp -d)"
      mkdir -p "$out"
      clj -Sdeps "{:mvn/local-repo \"$out\"}" -P -M:cljs
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      find $out -type f \( \
        -name \*.lastUpdated \
        -o -name resolver-status.properties \
        -o -name _remote.repositories \) \
        -delete
      runHook postInstall
    '';

    dontFixup = true;
    outputHash = "sha256-gcq9zP5AQtpZU7sC9Oq3PkTj6uDo2NSShigkcuglV98=";
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  };

  # ------------------------------------------------------------------ #
  # Yarn offline caches (same hashes as the desktop derivation because  #
  # they are derived from the same source tree and lockfiles).          #
  # ------------------------------------------------------------------ #
  yarnOfflineCacheRoot = fetchYarnDeps {
    name = "logseq-md-${finalAttrs.version}-yarn-deps-root";
    inherit (finalAttrs) src patches;
    hash = "sha256-dYzozo2wo4lZRi3R7S/f5yqVlLlF/TmrwkD4/xsGQAE=";
  };

  yarnOfflineCacheStaticResources = fetchYarnDeps {
    name = "logseq-md-${finalAttrs.version}-yarn-deps-static-resources";
    inherit (finalAttrs) src patches;
    postPatch = "cd ./static";
    hash = "sha256-uQZ07miqXVX1loy3JrA3h64dfEhg5wtLmpzxFgMFVC0=";
  };

  yarnOfflineCacheAmplify = fetchYarnDeps {
    name = "logseq-md-${finalAttrs.version}-yarn-deps-amplify";
    inherit (finalAttrs) src patches;
    postPatch = "cd ./packages/amplify";
    hash = "sha256-IOhSwIf5goXCBDGHCqnsvWLf3EUPqq75xfQg55snIp4=";
  };

  yarnOfflineCacheTldraw = fetchYarnDeps {
    name = "logseq-md-${finalAttrs.version}-yarn-deps-tldraw";
    inherit (finalAttrs) src patches;
    postPatch = "cd ./tldraw";
    hash = "sha256-CtMl3MPlyO5nWfFhCC1SLb/+1HUM3YfFATAPqJg3rUo=";
  };

  yarnOfflineCacheLibs = fetchYarnDeps {
    name = "logseq-md-${finalAttrs.version}-yarn-deps-libs";
    inherit (finalAttrs) src patches;
    postPatch = "cd ./libs";
    hash = "sha256-m5ZwYpRrTUeSFfbeViBcABaP2bAhY6p/ZQptmU4YxFY=";
  };

  # ------------------------------------------------------------------ #
  # Gradle / Maven dependency cache.                                    #
  #                                                                     #
  # This fixed-output derivation is allowed network access and runs a  #
  # full `assembleRelease` against placeholder web assets so that every #
  # Maven artifact and Gradle build-cache entry required by the real    #
  # build is present in $GRADLE_USER_HOME before we enter the          #
  # network-isolated main derivation.                                   #
  #                                                                     #
  # Replace `lib.fakeHash` with the real hash printed by Nix the first #
  # time you attempt to build this package.                             #
  # ------------------------------------------------------------------ #
  gradleDeps = stdenv.mkDerivation {
    name = "logseq-md-${finalAttrs.version}-gradle-deps";
    inherit (finalAttrs) src patches;
    inherit (finalAttrs) yarnOfflineCacheRoot;

    nativeBuildInputs = [
      androidSdk.androidsdk
      gradle_8-unwrapped
      jdk17
      nodejs-slim
      yarnConfigHook
    ];

    dontYarnInstallDeps = true;

    buildPhase = ''
      runHook preBuild

      export HOME=$(mktemp -d)
      export GRADLE_USER_HOME=$(mktemp -d)
      export ANDROID_HOME="${androidSdk.androidsdk}/libexec/android-sdk"
      export ANDROID_SDK_ROOT="$ANDROID_HOME"
      # AGP 8.1 is incompatible with JDK 21's jlink; force JDK 17.
      export JAVA_HOME="${jdk17}"

      # Install root node_modules so that:
      #   • the Capacitor CLI (node_modules/.bin/cap) is available, and
      #   • the plugin source paths referenced in capacitor.settings.gradle
      #     (e.g. ../node_modules/@capacitor/android/capacitor) resolve.
      yarnOfflineCache="$yarnOfflineCacheRoot" yarnConfigHook
      patchShebangs node_modules

      # capacitor.config.ts reads the app version from static/package.json.
      cp resources/package.json static/package.json

      # webDir (./public) must exist for `cap sync` to succeed; the
      # contents are placeholder-only at this stage.
      mkdir -p public

      # Create android/capacitor-cordova-android-plugins and write
      # android/app/src/main/assets/capacitor.config.json.
      node_modules/.bin/cap sync android

      # Use the SDK's Nix-patched aapt2 instead of the Maven-downloaded one
      # (the Maven binary is an unpatched ELF that can't run in the Nix sandbox).
      echo "android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/33.0.2/aapt2" >> android/gradle.properties

      # Run a full release build so that every Maven artifact and
      # Gradle build-cache entry gets populated.  Web assets are only
      # placeholders here; the real assets are injected during the
      # main build and cause affected tasks to re-run from source.
      pushd android
      gradle --no-daemon assembleRelease
      popd

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      # Quickly remove the largest caches known to contain Nix store paths
      # (jlink-produced JDK images, task-output snapshots, JDK metadata).
      rm -rf \
        "$GRADLE_USER_HOME/caches/transforms-"* \
        "$GRADLE_USER_HOME/caches/build-cache-"* \
        "$GRADLE_USER_HOME/caches/jdks-"*

      # Sweep any remaining files that still reference Nix store paths
      # (daemon registry, Gradle-version metadata, etc.).
      # Maven artifact files (jars, poms) never contain Nix store paths
      # and will be preserved intact.
      grep -rl '/nix/store' "$GRADLE_USER_HOME" 2>/dev/null | xargs -r rm -f

      cp -r "$GRADLE_USER_HOME" "$out"
      runHook postInstall
    '';

    dontFixup = true;

    outputHash = "sha256-Xwm9YDce45PvvjLjzzQMdHVPjguMSqtgXm5hyQX2uPI=";
    outputHashMode = "recursive";
  };

  # ------------------------------------------------------------------ #
  # Main derivation                                                     #
  # ------------------------------------------------------------------ #

  strictDeps = true;
  __structuredAttrs = true;

  nativeBuildInputs =
    let
      clojureWithCache = writeShellScriptBin "clojure" ''
        exec ${lib.getExe' clojure "clojure"} -Sdeps '{:mvn/local-repo "${finalAttrs.mavenRepo}"}' "$@"
      '';

      fakeGit = writeShellScriptBin "git" ''
        echo "${finalAttrs.src.rev or finalAttrs.version}@nixpkgs"
      '';
    in
    [
      androidSdk.androidsdk
      clojureWithCache
      fakeGit
      gradle_8-unwrapped
      jdk17
      nodejs-slim
      nodejs-slim.npm
      yarnConfigHook
    ];

  dontYarnInstallDeps = true;

  env = {
    ANDROID_HOME = "${androidSdk.androidsdk}/libexec/android-sdk";
    ANDROID_SDK_ROOT = "${androidSdk.androidsdk}/libexec/android-sdk";
  };

  postConfigure = ''
    yarnOfflineCache="$yarnOfflineCacheRoot" yarnConfigHook

    cp resources/package.json static/package.json
    pushd static
    yarnOfflineCache="$yarnOfflineCacheStaticResources" yarnConfigHook
    popd

    pushd packages/amplify
    yarnOfflineCache="$yarnOfflineCacheAmplify" yarnConfigHook
    patchShebangs node_modules
    # Build dist/amplify.js (the postinstall step that yarn skips in offline mode).
    yarn --offline build:amplify
    popd

    pushd tldraw
    cp yarn.lock apps/tldraw-logseq/yarn.lock
    yarnOfflineCache="$yarnOfflineCacheTldraw" yarnConfigHook
    pushd apps/tldraw-logseq
    yarnOfflineCache="$yarnOfflineCacheTldraw" yarnConfigHook
    popd
    popd

    pushd libs
    yarnOfflineCache="$yarnOfflineCacheLibs" yarnConfigHook
    popd

    patchShebangs node_modules
    patchShebangs static/node_modules
    patchShebangs packages/amplify/node_modules
    patchShebangs tldraw/node_modules
    patchShebangs tldraw/apps/tldraw-logseq/node_modules
    patchShebangs libs/node_modules

    yarn --offline --cwd tldraw postinstall

    # Regenerate lsplugin.*.js from TypeScript sources in libs/.
    rm resources/js/lsplugin.*.js

    pushd libs

    substituteInPlace webpack.config.core.js \
      --replace-fail "config.plugins.push(new BundleAnalyzerPlugin())" ""

    npm run build
    npm run build:core
    mv dist/lsplugin.*.js ../resources/js/

    popd
  '';

  buildPhase = ''
    runHook preBuild

    # 1. Build the web app (mobile/browser target only; no Electron output).
    NODE_ENV=production node_modules/.bin/gulp build
    clojure -M:cljs release app \
      --config-merge "{:compiler-options {:output-feature-set :es6}}"

    # 2. Assemble the Capacitor webDir.
    #
    #    public/index.html is committed to the repo and references assets
    #    under static/.  The build produces those assets in static/, so
    #    we move static/ into public/ (creating public/static/) to match
    #    what the committed index.html expects.
    rm -rf public/static
    find static/js -name "*.map" -delete
    mv static public

    # 3. Recreate static/package.json so that capacitor.config.ts can
    #    read the app version when `cap sync` runs below.
    mkdir -p static
    cp resources/package.json static/package.json

    # 4. Sync web assets and plugin configuration into the Android project.
    #    This copies public/ → android/app/src/main/assets/public/ and
    #    regenerates android/capacitor-cordova-android-plugins/.
    node_modules/.bin/cap sync android

    # 5. Build the release APK using the pre-fetched Gradle dependency
    #    cache.  The --offline flag prevents any outbound Maven traffic.
    export GRADLE_USER_HOME=$(mktemp -d)
    cp -r "${finalAttrs.gradleDeps}/." "$GRADLE_USER_HOME/"
    chmod -R u+w "$GRADLE_USER_HOME"
    # AGP 8.1 is incompatible with JDK 21's jlink; force JDK 17.
    export JAVA_HOME="${jdk17}"
    # Use the SDK's Nix-patched aapt2 instead of the Maven-downloaded one.
    echo "android.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/33.0.2/aapt2" >> android/gradle.properties

    pushd android
    gradle --no-daemon --offline assembleRelease
    popd

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm644 \
      android/app/build/outputs/apk/release/app-release-unsigned.apk \
      "$out/logseq-md.apk"

    runHook postInstall
  '';

  meta = {
    description = "Privacy-first, open-source platform for knowledge management and collaboration (Android APK)";
    homepage = "https://github.com/Gipphe/logseq-md";
    license = lib.licenses.agpl3Only;
    maintainers = with lib.maintainers; [ tomasajt ];
    # Android toolchain is only available on Linux hosts.
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
})
