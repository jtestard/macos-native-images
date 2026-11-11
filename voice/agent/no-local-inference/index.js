// This project uses only open-source components. @livekit/local-inference
// bundles models under the proprietary LiveKit Model License, so package.json
// overrides it with this package. LiveKit Agents loads it in a try/catch and,
// when loading fails, disables only its local turn-detection models. The agent
// uses the Silero VAD plugin instead.
throw new Error('@livekit/local-inference is intentionally not installed');
