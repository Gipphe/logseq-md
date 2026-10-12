{
  lib,
  androidenv,
  jdk17,
  writeShellApplication,
  logseq-md-android,
}:

let
  # Separate SDK composition for running the emulator.
  # Includes system images and the emulator binary, which are not needed
  # for building the APK and would bloat the build-time SDK.
  emulatorSdk = (androidenv.composeAndroidPackages {
    buildToolsVersions = [ "33.0.2" ];
    platformVersions = [ "33" ];
    abiVersions = [ "x86_64" ];
    includeEmulator = true;
    includeSystemImages = true;
    systemImageTypes = [ "google_apis" ];
    includeNDK = false;
    includeExtras = [ ];
  }).androidsdk;

  package = "com.logseq.og";
  activity = "com.logseq.og.MainActivity";
  api = "33";
  abi = "x86_64";
  systemImage = "google_apis";

in
writeShellApplication {
  name = "logseq-md-emulator";

  # keytool comes from jdk17; avdmanager/adb from the emulator SDK.
  runtimeInputs = [
    jdk17
    emulatorSdk
  ];

  text = ''
    apk="${logseq-md-android}/logseq-md.apk"
    sdk_root="${emulatorSdk}/libexec/android-sdk"
    avd_name="logseq-md"

    data_home="$HOME/.local/share"
    if [ -n "''${XDG_DATA_HOME:-}" ]; then
      data_home="$XDG_DATA_HOME"
    fi
    app_data="$data_home/logseq-md-emulator"
    keystore="$app_data/debug.keystore"
    avd_home="$app_data/avd"

    export ANDROID_SDK_ROOT="$sdk_root"
    export ANDROID_AVD_HOME="$avd_home"
    export ANDROID_USER_HOME="$app_data"

    mkdir -p "$app_data" "$avd_home"

    # ── Sign the APK with a local debug certificate ──────────────────────────
    if [ ! -f "$keystore" ]; then
      echo "Generating debug keystore at $keystore ..."
      keytool -genkeypair \
        -keystore "$keystore" \
        -alias androiddebugkey \
        -keyalg RSA -keysize 2048 \
        -validity 10000 \
        -storepass android \
        -keypass android \
        -dname "CN=Android Debug,O=Android,C=US"
    fi

    signed_apk="$(mktemp /tmp/logseq-md-XXXXXX.apk)"
    cp "$apk" "$signed_apk"
    chmod +w "$signed_apk"
    echo "Signing APK..."
    "$sdk_root/build-tools/33.0.2/apksigner" sign \
      --ks "$keystore" \
      --ks-key-alias androiddebugkey \
      --ks-pass pass:android \
      --key-pass pass:android \
      "$signed_apk"

    # ── Create AVD if it does not exist yet ───────────────────────────────────
    if ! avdmanager list avd -c 2>/dev/null | grep -qx "$avd_name"; then
      echo "Creating AVD '$avd_name' (API ${api}, ${abi}, ${systemImage})..."
      # 'echo no' answers "Do you wish to create a custom hardware profile?"
      echo "no" | avdmanager create avd \
        --force \
        --name "$avd_name" \
        --package "system-images;android-${api};${systemImage};${abi}" \
        --path "$avd_home/$avd_name.avd"
    fi

    # ── Find a free emulator port ─────────────────────────────────────────────
    port=""
    p=5554
    while [ "$p" -le 5584 ] && [ -z "$port" ]; do
      if ! adb devices | grep -q "emulator-$p"; then
        port="$p"
      fi
      p=$((p + 2))
    done
    if [ -z "$port" ]; then
      echo "No free emulator port available in range 5554–5584." >&2
      exit 1
    fi
    echo "Using port $port."

    # ── Start the emulator ────────────────────────────────────────────────────
    emulator_pid=""
    cleanup() {
      if [ -n "$emulator_pid" ]; then
        echo "Stopping emulator..."
        kill "$emulator_pid" 2>/dev/null || true
      fi
      rm -f "$signed_apk"
    }
    trap cleanup EXIT INT TERM

    echo "Starting emulator on port $port..."
    # shellcheck disable=SC2086
    "$sdk_root/emulator/emulator" \
      -avd "$avd_name" \
      -no-boot-anim \
      -port "$port" \
      ''${NIX_ANDROID_EMULATOR_FLAGS:-} &
    emulator_pid=$!

    # ── Wait for the device to finish booting ─────────────────────────────────
    echo "Waiting for emulator to boot (this may take a minute)..."
    adb -s "emulator-$port" wait-for-device
    boot_done=""
    while [ "$boot_done" != "1" ]; do
      sleep 3
      boot_done="$(adb -s "emulator-$port" shell getprop dev.bootcomplete 2>/dev/null \
                     | tr -d '\r')" || true
    done
    echo "Emulator ready."

    # ── Install and launch the app ────────────────────────────────────────────
    echo "Installing logseq-md..."
    adb -s "emulator-$port" install -r "$signed_apk"

    echo "Launching ${package}..."
    adb -s "emulator-$port" shell am start \
      -a android.intent.action.MAIN \
      -n "${package}/${activity}"

    echo "App is running.  Close the emulator window or press Ctrl+C to quit."
    wait "$emulator_pid"
    emulator_pid=""
  '';

  meta = {
    description = "Run logseq-md in an Android emulator (x86_64, API 33)";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
