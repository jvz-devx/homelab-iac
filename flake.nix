{
  description = "Homelab IaC: k3s + FluxCD + Ansible + SOPS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            ansible
            fluxcd
            kubectl
            kubernetes-helm
            sops
            age
            cloudflared
            k9s
            jq
            yq-go
            pre-commit
            yamllint
          ];

          shellHook = ''
            export KUBECONFIG="$PWD/kubeconfig"
            export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
            pre-commit install --allow-missing-config >/dev/null 2>&1 || true
            echo "Homelab IaC devShell loaded"
            echo "Tools: ansible, flux, kubectl, helm, sops, age, cloudflared, k9s"
            if [[ ! -f "$KUBECONFIG" ]]; then
              echo "⚠ no kubeconfig at $KUBECONFIG — run ./scripts/fetch-kubeconfig.sh once"
            fi
          '';
        };
      });
}
