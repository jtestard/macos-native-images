# macOS native images

`darwin/arm64` OCI images of open-source servers that run natively on Apple
Silicon Macs, with Metal, through the
[macOS container runtime](https://github.com/jtestard/macos-container-runtime).
They are macOS programs, not Linux binaries, and run on the Mac's network
without a VM.

| Image | Upstream | What it serves |
| --- | --- | --- |
| [`jtstormz/llama-server`](https://hub.docker.com/r/jtstormz/llama-server) | [llama.cpp](https://github.com/ggml-org/llama.cpp) `ee0445c` | OpenAI-compatible chat completions on port 8082. Model-free: mount a GGUF. |
| [`jtstormz/whisper-server`](https://hub.docker.com/r/jtstormz/whisper-server) | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `v1.9.1` | Speech-to-text on port 8000 (`/v1/audio/transcriptions`), with the English base model. |
| [`jtstormz/kokoro`](https://hub.docker.com/r/jtstormz/kokoro) | [Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI) `b4ef64b` | Text-to-speech on port 8880 (`/v1/audio/speech`) on Metal (MPS), with the Kokoro-82M weights. |

Each image is tagged with its upstream version, for example
`jtstormz/llama-server:ee0445c`. The images are built from unmodified upstream
sources; this repository only holds the build recipes.

## Use an image

With the runtime installed, pass its `macnative` Docker context:

```sh
docker --context macnative pull jtstormz/whisper-server:v1.9.1-base.en
docker --context macnative run -d --name whisper jtstormz/whisper-server:v1.9.1-base.en
curl http://127.0.0.1:8000/v1/audio/transcriptions -F file=@speech.wav
```

To leave out `--context`, run `docker context use macnative` once; switch back
with `docker context use desktop-linux`.

`llama-server` needs a model directory mounted read-only at `/app/models`; see
the runtime's README for a complete example. The servers listen on loopback
ports of the Mac directly; `-p` is not supported.

## Build the images

You need an Apple Silicon Mac with the Command Line Tools
(`xcode-select --install`), Go, CMake (`brew install cmake`), and the
runtime's native BuildKit worker registered as the `macnative-build` Buildx
builder; the runtime README's "Build a Darwin image" section sets it up.

```sh
make all              # or: make llama-server | whisper-server | kokoro
```

Sources, models and tools are downloaded into `.build/` at the versions pinned
in the [Makefile](Makefile), and each image is written to
`.build/<image>.tar` as an OCI tarball. The runtime can run a tarball directly:
`macd -load <name>:<tag>=.build/<image>.tar`.

To publish, log in to Docker Hub as the target account and push:

```sh
docker login
make push             # or: make push-llama-server, ...
make push NAMESPACE=yourname
```

`NAMESPACE` (default `jtstormz`) selects the Docker Hub account. The push uses
[crane](https://github.com/google/go-containerregistry/tree/main/cmd/crane)
through `go run`, so nothing else needs installing.

## Notes

- The native BuildKit worker runs `RUN` steps in a host snapshot, so the
  Dockerfiles derive the snapshot path and use the host's compiler through
  `xcrun`. CMake may print harmless `xcrun: error: couldn't create cache file`
  lines.
- The Kokoro image includes a small [launcher](launcher/main.go) that starts
  Python from wherever the runtime extracted the image. Kokoro logs a harmless
  permission warning when Metal cannot write its shader cache.
- Kokoro's Python dependencies are resolved from upstream version ranges at
  build time, so a later rebuild can pick newer packages.

## License

The build recipes are [MIT licensed](LICENSE). Each image contains software and
model weights under their own upstream licenses: llama.cpp and whisper.cpp
(MIT), Kokoro-FastAPI (Apache 2.0), Kokoro-82M (Apache 2.0), and the Whisper
model (MIT).
