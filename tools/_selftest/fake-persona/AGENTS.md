# Fake Persona (self-test fixture)

- This directory is a throwaway persona pack for the `tools\New-Disc.ps1` self-test. It contains no real persona.
- It only proves the chain: pack -> hash manifest -> static checks -> checks fail after a file is tampered with.
- Put a real Persona Pack under `persona\` in the workspace; do not reuse this directory.
