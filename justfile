install:
  moon update
  moon build cmd/moonless --target native
  mkdir -p "$HOME/.local/bin"
  cp "$PWD/_build/native/debug/build/cmd/moonless/moonless.exe" "$HOME/.local/bin/moonless" || true

