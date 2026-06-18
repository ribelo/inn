{
  description = "Inn OxCaml local OpenTelemetry collector and query service";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          oxCamlSwitch = "5.2.0+ox";
          oxCamlOpamRoot = "$HOME/.cache/opam";
          nativePkgConfigPath = pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" (
            [ pkgs.sqlite ]
          );
          oxCamlSetup = pkgs.writeShellApplication {
            name = "inn-oxcaml-init";
            runtimeInputs = [
              pkgs.autoconf
              pkgs.git
              pkgs.gnumake
              pkgs.m4
              pkgs.opam
              pkgs.patch
              pkgs.pkg-config
              pkgs.python3
              pkgs.sqlite
            ];
            text = ''
              switch_name="''${1:-${oxCamlSwitch}}"
              repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
              cd "$repo_root"

              export OPAMROOT="''${OPAMROOT:-${oxCamlOpamRoot}}"
              export OPAMYES=1
              export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"
              eta_pin="''${ETA_OPAM_PIN:-git+https://github.com/ribelo/eta.git#master}"

              if [ ! -d "$OPAMROOT" ]; then
                opam init --bare --disable-sandboxing --no-setup --yes
              fi

              if ! opam switch list --short | grep -Fxq "$switch_name"; then
                opam switch create "$switch_name" \
                  --repos ox=git+https://github.com/oxcaml/opam-repository.git,default \
                  --assume-depexts \
                  --yes
              fi

              export OPAMSWITCH="$switch_name"
              eval "$(opam env --switch "$switch_name" --set-switch)"

              for pkg in \
                eta \
                eta_blocking \
                eta_eio \
                eta_http \
                eta_http_eio \
                eta_sql \
                eta_sql_driver \
                eta_sql_dsl \
                eta_stream; do
                opam pin add "$pkg" "$eta_pin" --yes
              done
              opam install . --deps-only --with-test --assume-depexts --yes

              echo "OxCaml switch is ready: $switch_name"
              echo "Enter it with: nix develop .#oxcaml"
            '';
          };

          shellHook = ''
            export OPAMROOT="''${OPAMROOT:-${oxCamlOpamRoot}}"
            export PKG_CONFIG_PATH="${nativePkgConfigPath}:''${PKG_CONFIG_PATH:-}"
            if [ -d "$OPAMROOT/${oxCamlSwitch}" ]; then
              export OPAMSWITCH="${oxCamlSwitch}"
              eval "$(opam env --switch "${oxCamlSwitch}" --set-switch)"
            fi
            if [ -t 1 ]; then
              echo "Inn OxCaml shell (${oxCamlSwitch})"
              echo "Run 'inn-oxcaml-init' once to create the ${oxCamlSwitch} opam switch."
            fi
          '';
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.autoconf
              pkgs.cacert
              pkgs.git
              pkgs.gnumake
              pkgs.m4
              pkgs.opam
              pkgs.patch
              pkgs.pkg-config
              pkgs.sqlite
              pkgs.unzip
              pkgs.which
              oxCamlSetup
            ];

            inherit shellHook;
          };

          oxcaml = pkgs.mkShell {
            packages = [
              pkgs.autoconf
              pkgs.cacert
              pkgs.git
              pkgs.gnumake
              pkgs.m4
              pkgs.opam
              pkgs.patch
              pkgs.pkg-config
              pkgs.sqlite
              pkgs.unzip
              pkgs.which
              oxCamlSetup
            ];

            inherit shellHook;
          };
        }
      );
    };
}
