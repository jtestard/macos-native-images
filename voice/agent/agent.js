// A voice agent that joins every LiveKit room and talks with the participant,
// using three local OpenAI-compatible servers: whisper-server for speech to
// text, llama-server for the replies, and Kokoro for text to speech.
import { fileURLToPath } from 'node:url';
import { cli, defineAgent, ServerOptions, voice } from '@livekit/agents';
import * as openai from '@livekit/agents-plugin-openai';
import * as silero from '@livekit/agents-plugin-silero';

const env = (name, fallback) => process.env[name] || fallback;

// The local servers do not check API keys, but the OpenAI client requires one.
const LOCAL_KEY = 'local';

const INSTRUCTIONS =
  'You are a friendly voice assistant running entirely on this Mac. ' +
  'Keep answers to one or two short sentences, in plain spoken English, ' +
  'without lists, markdown or emoji.';

export default defineAgent({
  prewarm: async (proc) => {
    proc.userData.vad = await silero.VAD.load();
  },
  entry: async (ctx) => {
    await ctx.connect();
    const session = new voice.AgentSession({
      vad: ctx.proc.userData.vad,
      stt: new openai.STT({
        baseURL: env('STT_BASE_URL', 'http://127.0.0.1:20084/v1'),
        apiKey: LOCAL_KEY,
        model: 'whisper-1',
        language: 'en',
        useRealtime: false,
      }),
      llm: new openai.LLM({
        baseURL: env('LLM_BASE_URL', 'http://127.0.0.1:20082/v1'),
        apiKey: LOCAL_KEY,
        model: env('LLM_MODEL', 'local'),
      }),
      tts: new openai.TTS({
        baseURL: env('TTS_BASE_URL', 'http://127.0.0.1:20085/v1'),
        apiKey: LOCAL_KEY,
        model: 'kokoro',
        voice: env('TTS_VOICE', 'af_heart'),
      }),
    });
    await session.start({
      agent: new voice.Agent({ instructions: INSTRUCTIONS }),
      room: ctx.room,
    });
    // Keep the greeting out of the chat history: some chat templates, such as
    // Mistral's, reject an assistant turn before the first user turn.
    session.say('Hi! I am running entirely on this Mac. What would you like to talk about?', {
      addToChatCtx: false,
    });
  },
});

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  cli.runApp(
    new ServerOptions({
      agent: fileURLToPath(import.meta.url),
      wsURL: env('LIVEKIT_URL', 'ws://127.0.0.1:30880'),
      apiKey: env('LIVEKIT_API_KEY', 'devkey'),
      apiSecret: env('LIVEKIT_API_SECRET', 'secret'),
      // Health and metrics endpoint (the framework default, 8081, is left free).
      port: Number(env('AGENT_PORT', '20083')),
    }),
  );
}
