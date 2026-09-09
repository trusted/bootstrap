# Trusted Setup

## Usage

Open your terminal and paste the following command. Popular options are Ghostty and iTerm2.

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/trusted/bootstrap/main/install.sh)"
```

You can run this as many times as you want, whenever you want.

## How it works

This repo contains an installation script (install.sh) that does a lightweight initial bootstrapping,
including authenticating with Github, then hands over to the full setup at https://github.com/trusted/setup
which does the heavy lifting. It will setup a Standard Development Environment.

## Contributing

Keep this repository and its installation script at a minimum. You most likely want to add things
to https://github.com/trusted/setup instead of changing anything here.
