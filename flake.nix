{
  description = "Inn OxCaml local OpenTelemetry collector and query service";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.ox = {
    url = "git+file:///home/ribelo/projects/ribelo/ocaml/ox?ref=master";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.opam-nix.follows = "opam-nix";
    inputs.opam-repository.follows = "opam-repository";
    inputs.oxcaml.follows = "oxcaml";
    inputs.oxcaml-opam-repository.follows = "oxcaml-opam-repository";
  };
  inputs.opam-nix = {
    url = "github:tweag/opam-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.opam-repository = {
    url = "github:ocaml/opam-repository/4fde328c35c75c2c7269e426a3cf041888890018";
    flake = false;
  };
  inputs.oxcaml-opam-repository = {
    url = "github:oxcaml/opam-repository/d65f081024758576f7a848bbd369863e7f7c1e81";
    flake = false;
  };
  inputs.oxcaml = {
    url = "github:oxcaml/oxcaml/5.4.0-ox2";
    flake = false;
  };

  outputs =
    {
      nixpkgs,
      ox,
      opam-nix,
      opam-repository,
      oxcaml,
      oxcaml-opam-repository,
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
          oxSrc = cleanLocalSource ox;
          opamLib = opam-nix.lib.${system};
          oxRepo = opamLib.makeOpamRepo oxSrc;
          patchedOxcaml = pkgs.runCommand "oxcaml-source-patched" { } ''
            cp -R ${oxcaml} "$out"
            chmod -R u+w "$out"
            substituteInPlace "$out/default.nix" \
              --replace-fail 'version = "5.2.0+ox";' 'version = "5.4.0+ox";'
            ${pkgs.perl}/bin/perl -0pi -e 's|new: old: \{\n        buildInputs = \[|new: old: rec {\n        version = "20231231";\n        src = pkgs.fetchFromGitLab {\n          domain = "gitlab.inria.fr";\n          owner = "fpottier";\n          repo = "menhir";\n          rev = version;\n          sha256 = "sha256-veB0ORHp6jdRwCyDDAfc7a7ov8sOeHUmiELdOFf/QYk=";\n        };\n        patches = [ ];\n        buildInputs = [|' "$out/default.nix"
          '';
          oxcamlCompiler =
            (pkgs.callPackage "${patchedOxcaml}/default.nix" {
              src = patchedOxcaml;
              ocamltest = true;
              warnError = false;
            }).overrideAttrs (_old: {
              doCheck = false;
            });
          oxcamlSystemOverlay = final: prev: {
            ocaml-system = prev.ocaml-system.overrideAttrs (old: {
              nativeBuildInputs = [ oxcamlCompiler ];
              preBuild = (old.preBuild or "") + ''
                substituteInPlace gen_ocaml_config.ml \
                  --replace-fail '5.4.0' '5.4.0+ox'
              '';
            });
            ocaml-config = prev.ocaml-config.overrideAttrs (old: {
              postInstall = (old.postInstall or "") + ''
                ln -s ocaml-config/gen_ocaml_config.ml \
                  "$out/share/gen_ocaml_config.ml"
              '';
            });
            ocamlfind = prev.ocamlfind.overrideAttrs (old: {
              postFixup = (old.postFixup or "") + ''
                replacement='"'"$out"'/lib/ocaml/5.4.0/site-lib/toplevel"'
                substituteInPlace "$out/bin/ocaml" \
                  --replace-fail '"$OCAML_TOPLEVEL_PATH"' "$replacement"
              '';
            });
            topkg = prev.topkg.overrideAttrs (old: {
              buildPhase = builtins.replaceStrings
                [ ''args+=("ocaml")'' ]
                [ ''args+=("${final.ocamlfind}/bin/ocaml")'' ]
                old.buildPhase;
            });
            fmt = prev.fmt.overrideAttrs (old: {
              buildPhase = builtins.replaceStrings
                [ ''args+=("ocaml")'' ]
                [ ''args+=("${final.ocamlfind}/bin/ocaml")'' ]
                old.buildPhase;
            });
            mtime = prev.mtime.overrideAttrs (old: {
              buildPhase = builtins.replaceStrings
                [ ''args+=("ocaml")'' ]
                [ ''args+=("${final.ocamlfind}/bin/ocaml")'' ]
                old.buildPhase;
            });
          };
          scope = opamLib.buildOpamProject
            {
              inherit pkgs;
              overlays = [ oxcamlSystemOverlay ];
              repos = [
                # Upstream Eio 1.6 from ox, never the oxcaml/eio snapshot (ox ^neio-w4hd).
                ox.legacyPackages.${system}.eioOpamRepository
                oxRepo
                oxcaml-opam-repository
                opam-repository
              ];
              resolveArgs.env.sys-ocaml-version = "5.4.0";
            }
            "inn"
            innSrc
            {
              angstrom = "0.16.1";
              faraday = "0.8.2";
              ocaml-system = "*";
              yojson = "2.2.2+ox";
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
          oxCamlSwitch = "5.4.0+ox";
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

              ox_path="''${OX_PATH:-$repo_root/../ocaml/ox}"
              if command -v ox-opam-install >/dev/null 2>&1; then
                OX_REPO_ROOT="$ox_path" ox-opam-install
              elif [ -d "$ox_path" ]; then
                OX_REPO_ROOT="$ox_path" nix develop "$ox_path" -c ox-opam-install
              else
                echo "Missing Ox checkout at $ox_path" >&2
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
