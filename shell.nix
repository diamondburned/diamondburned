{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
	buildInputs = with pkgs; [
		curl
		jq
		bash
		coreutils
	];
}
