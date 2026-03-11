{ lib, buildNpmPackage, fetchurl, nodejs_22 }:

buildNpmPackage rec {
  pname = "openclaw";
  version = "2026.2.22-2";

  src = fetchurl {
    url = "https://registry.npmjs.org/openclaw/-/openclaw-${version}.tgz";
    sha256 = "18lg26928gss3ndasyb6yc2a6ijk682p6c6qy8f4sd6wz3bvg6fp";
  };

  # Derived from the lockfile in this repository.
  npmDepsHash = "sha256-cmF0eG2CYAOlwV/TH51lfltyRvrCeDcP+ruNMhdwPdw=";

  # Upstream package has peer deps that require legacy resolution mode.
  npmFlags = [ "--legacy-peer-deps" ];
  npmPackFlags = [ "--ignore-scripts" ];
  makeCacheWritable = true;
  dontNpmBuild = true;

  postPatch = ''
    cp ${./openclaw-package-lock.json} package-lock.json
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/node_modules/${pname}"
    cp -r . "$out/lib/node_modules/${pname}/"

    mkdir -p "$out/bin"
    cat > "$out/bin/openclaw" <<WRAP
#!/usr/bin/env bash
exec ${nodejs_22}/bin/node "$out/lib/node_modules/${pname}/openclaw.mjs" "\$@"
WRAP
    chmod +x "$out/bin/openclaw"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Self-hosted multi-channel AI gateway";
    homepage = "https://github.com/openclaw/openclaw";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "openclaw";
  };
}
