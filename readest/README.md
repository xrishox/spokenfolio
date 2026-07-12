# Readest helper

The integration contract, codec negotiation, buffer behavior, fork boundary,
and rebase commands are in
[docs/READEST_INTEGRATION.md](../docs/READEST_INTEGRATION.md).

Clone the maintained branch normally:

```bash
git clone --branch custom-openai-tts-implementation \
  https://github.com/xrishox/readest.git
cd readest
pnpm install
pnpm --filter @readest/readest-app setup-vendors
```

Alternatively, from the root of this server repository, the Linux helper
clones/updates its own ignored checkout and builds an AppImage:

```bash
./readest/build-appimage.sh
```

Configure Readest's **OpenAI-Compatible TTS** endpoint as
`http://<mac-host>:8787`, leave the key empty on the trusted LAN, press **Test**,
and select the full Siri voice ID.
