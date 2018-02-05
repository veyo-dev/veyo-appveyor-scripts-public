# veyo-appveyor-scripts #

Various public scripts for AppVeyor build projects:

1. `generate-package-version.ps1`:
    * Generates and sets the build version based on the Git branch name and the current AppVeyor build version in the `major.minor.patch.build` format. Uses the semver-2.0 version format with build metadata.
    * Ensures that the AppVeyor NuGet feed does not contain a package with the same package id(s) and generated version.
