#!/bin/bash
set -euo pipefail

solutionPath=$(pwd "$0")
sdkFile="$solutionPath/global.json"

dotnetVersion=$(grep '"sdk": {' "$sdkFile" -A 5 | grep '"version":' | sed -E 's/.*"version": "(.*)".*/\1/')

installDotNetSdk=false

if ! command -v dotnet &> /dev/null; then
    echo "The .NET SDK is not installed."
    installDotNetSdk=true
else
    installedDotNetVersion=$(dotnet --version 2>&1 || echo "?")
    if [ "$installedDotNetVersion" != "$dotnetVersion" ]; then
        echo "The required version of the .NET SDK is not installed. Expected $dotnetVersion."
        installDotNetSdk=true
    fi
fi

if [ "$installDotNetSdk" = true ]; then
    DOTNET_INSTALL_DIR="$solutionPath/.dotnet"
    sdkPath="$DOTNET_INSTALL_DIR/sdk/$dotnetVersion"

    if [ ! -d "$sdkPath" ]; then
        installScript="./install-dotnet.sh"
        curl -sSL https://dot.net/v1/dotnet-install.sh -o "$installScript"
        chmod +x "$installScript"
        "$installScript" --version "$dotnetVersion" --install-dir "$DOTNET_INSTALL_DIR" --no-path --skip-non-versioned-files "$@"
    fi
else
    DOTNET_INSTALL_DIR=$(dirname "$(command -v dotnet)")
fi
