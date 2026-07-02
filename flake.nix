{
  description = "Inn OxCaml local OpenTelemetry collector and query service";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.eta = {
    url = "git+file:///home/ribelo/projects/ribelo/ocaml/Eta";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.opam-nix.follows = "opam-nix";
    inputs.opam-repository.follows = "opam-repository";
    inputs.oxcaml.follows = "oxcaml";
  };
  inputs.opam-nix = {
    url = "github:tweag/opam-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.opam-repository = {
    url = "github:ocaml/opam-repository";
    flake = false;
  };
  inputs.oxcaml = {
    url = "github:oxcaml/oxcaml/5.2.0minus-31";
    flake = false;
  };

  outputs =
    {
      nixpkgs,
      eta,
      opam-nix,
      opam-repository,
      oxcaml,
      ...
    }:
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
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          cleanLocalSource =
            src:
            pkgs.lib.cleanSourceWith {
              inherit src;
              filter =
                path: _type:
                let
                  base = baseNameOf path;
                in
                !(
                  base == ".git"
                  || base == "_build"
                  || base == "_opam"
                  || base == ".opam"
                  || base == ".opam-oxcaml"
                  || base == ".reference"
                  || base == ".scratch"
                  || base == ".motel-data"
                  || base == ".nema"
                  || base == ".pi"
                  || base == ".hill-climbing"
                  || base == "node_modules"
                );
            };
          innSrc = cleanLocalSource ./.;
          etaSrc = cleanLocalSource eta;
          opamLib = opam-nix.lib.${system};
          etaRepo = opamLib.makeOpamRepo etaSrc;
          patchedOxcaml = pkgs.runCommand "oxcaml-source-patched" { } ''
            cp -R ${oxcaml} "$out"
            chmod -R u+w "$out"
            ${pkgs.perl}/bin/perl -0pi -e 's|new: old: \{\n        buildInputs = \[|new: old: rec {\n        version = "20231231";\n        src = pkgs.fetchFromGitLab {\n          domain = "gitlab.inria.fr";\n          owner = "fpottier";\n          repo = "menhir";\n          rev = version;\n          sha256 = "sha256-veB0ORHp6jdRwCyDDAfc7a7ov8sOeHUmiELdOFf/QYk=";\n        };\n        patches = [ ];\n        buildInputs = [|' "$out/default.nix"
          '';
          oxcamlCompiler = pkgs.callPackage "${patchedOxcaml}/default.nix" {
            src = patchedOxcaml;
            ocamltest = false;
            warnError = false;
          };
          oxcamlSystemOverlay = final: prev: {
            ocaml-system = prev.ocaml-system.overrideAttrs (_old: {
              nativeBuildInputs = [ oxcamlCompiler ];
            });
          };
          scope = opamLib.buildOpamProject
            {
              inherit pkgs;
              overlays = [ oxcamlSystemOverlay ];
              repos = [
                etaRepo
                opam-repository
              ];
              resolveArgs.env.sys-ocaml-version = "5.2.0";
            }
            "inn"
            innSrc
            {
              ocaml-system = "*";
            };
          inn = scope.inn;
        in
        {
          default = inn;
          inherit inn;
        }
      );

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
            name = "inn-opam-install";
            runtimeInputs = [
              pkgs.autoconf
              pkgs.coreutils
              pkgs.git
              pkgs.gnumake
              pkgs.m4
              pkgs.nix
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

              if ! opam switch list --short | grep -Fxq "$switch_name"; then
                echo "Missing OPAM switch '$switch_name'." >&2
                echo "Run: shared-ocaml-switch-init" >&2
                exit 1
              fi

              export OPAMSWITCH="$switch_name"
              eval "$(opam env --switch "$switch_name" --set-switch)"

              eta_path="''${ETA_PATH:-$repo_root/../ocaml/Eta}"
              if command -v eta-opam-install-ox >/dev/null 2>&1; then
                ETA_REPO_ROOT="$eta_path" eta-opam-install-ox
              elif [ -d "$eta_path" ]; then
                ETA_REPO_ROOT="$eta_path" nix develop "$eta_path" -c eta-opam-install-ox
              else
                echo "Missing Eta checkout at $eta_path" >&2
                exit 1
              fi

              opam pin add --kind=git inn "git+file://$repo_root#master" --no-action --yes
              opam install inn --assume-depexts --yes

              echo "Inn is installed into OPAM switch: $switch_name"
              echo "Enter it with: nix develop"
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
              echo "Run 'shared-ocaml-switch-init' before 'inn-opam-install'."
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
        }
      );
    };
}
