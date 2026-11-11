// End-to-end check of the voice stack without a microphone: joins a fresh room
// through the web client's /config endpoint, waits for the agent's greeting,
// speaks a WAV file, and prints the transcripts the agent publishes for both
// sides. Exits 0 once the agent has transcribed the speech and replied.
//
//   node test-conversation.js speech.wav [http://127.0.0.1:8090]
//
// The WAV must be 16-bit PCM, mono. On macOS:
//   say -o speech.aiff "What is the capital of France?"
//   afconvert -f WAVE -d LEI16@48000 -c 1 speech.aiff speech.wav
import { readFileSync } from 'node:fs';
import {
  AudioFrame, AudioSource, dispose, LocalAudioTrack, Room, TrackPublishOptions, TrackSource,
} from '@livekit/rtc-node';

const [wavPath, webURL = 'http://127.0.0.1:8090'] = process.argv.slice(2);
if (!wavPath) {
  console.error('usage: node test-conversation.js speech.wav [web-url]');
  process.exit(2);
}

function readWav(path) {
  const buf = readFileSync(path);
  let offset = 12, rate = 0, channels = 0, bits = 0;
  while (offset + 8 <= buf.length) {
    const id = buf.toString('ascii', offset, offset + 4);
    const size = buf.readUInt32LE(offset + 4);
    if (id === 'fmt ') {
      channels = buf.readUInt16LE(offset + 10);
      rate = buf.readUInt32LE(offset + 12);
      bits = buf.readUInt16LE(offset + 22);
    } else if (id === 'data') {
      if (bits !== 16 || channels !== 1) throw new Error('WAV must be 16-bit mono PCM');
      const pcm = new Int16Array(buf.buffer.slice(buf.byteOffset + offset + 8, buf.byteOffset + offset + 8 + size));
      return { rate, pcm };
    }
    offset += 8 + size + (size % 2);
  }
  throw new Error('no data chunk in WAV');
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitFor(check, ms, what) {
  for (const end = Date.now() + ms; Date.now() < end; await sleep(200)) if (check()) return;
  throw new Error(`timed out after ${ms / 1000}s waiting for ${what}`);
}

const { rate, pcm } = readWav(wavPath);
const config = await (await fetch(`${webURL}/config`)).json();
const room = new Room();
const transcripts = [];

// Each transcript segment is one text stream. The agent's own speech arrives
// as deltas on a stream that can stay open after it finishes speaking, so read
// chunks as they come and record the segment as soon as it has text.
// A segment can arrive more than once (interim, then final), so keep one entry
// per segment id and let the latest stream replace its text.
const bySegment = new Map();
room.registerTextStreamHandler('lk.transcription', async (reader, sender) => {
  const who = sender.identity === room.localParticipant.identity ? 'user' : 'agent';
  const segment = reader.info.attributes?.['lk.segment_id'] ?? reader.info.id;
  let entry = bySegment.get(segment);
  let text = '';
  try {
    for await (const chunk of reader) {
      if (!entry) {
        entry = { who, text: '' };
        bySegment.set(segment, entry);
        transcripts.push(entry);
      }
      text += chunk;
      entry.text = text;
    }
  } catch {
    // The stream ends abnormally when the room disconnects.
  }
});
const spoke = (who, from = 0) => transcripts.slice(from).findIndex((t) => t.who === who && t.text.trim());

await room.connect(config.url, config.token);
console.log(`Joined room ${config.room}; waiting for the agent…`);
let failure = null;
try {
  await waitFor(() => room.remoteParticipants.size > 0, 60_000, 'the agent to join');
  await waitFor(() => spoke('agent') >= 0, 90_000, 'the agent greeting');
  // Speech that overlaps the greeting is ignored, so wait until it finishes.
  const agentState = () => [...room.remoteParticipants.values()][0]?.attributes?.['lk.agent.state'];
  await waitFor(() => agentState() === 'listening', 60_000, 'the agent to finish its greeting');

  const source = new AudioSource(rate, 1);
  const track = LocalAudioTrack.createAudioTrack('microphone', source);
  const publication = await room.localParticipant.publishTrack(
    track, new TrackPublishOptions({ source: TrackSource.SOURCE_MICROPHONE }));
  await publication.waitForSubscription(); // the agent must be listening before we speak
  const chunk = rate / 100; // 10 ms frames
  const lead = new Int16Array(rate); // one second of silence before speaking
  const silence = new Int16Array(rate * 2); // let the VAD see the end of speech
  for (const samples of [lead, pcm, silence]) {
    for (let i = 0; i < samples.length; i += chunk) {
      const data = samples.slice(i, i + chunk);
      await source.captureFrame(new AudioFrame(data, rate, 1, data.length));
    }
  }
  await waitFor(() => spoke('user') >= 0, 60_000, 'the speech transcript');
  const heard = spoke('user');
  await waitFor(() => spoke('agent', heard + 1) >= 0, 120_000, 'the agent reply');
  await sleep(5000); // let the reply finish streaming
  console.log('Conversation OK');
} catch (err) {
  failure = err;
  console.error(String(err.message ?? err));
} finally {
  for (const t of transcripts) if (t.text.trim()) console.log(`${t.who === 'user' ? 'You  ' : 'Agent'}: ${t.text.trim()}`);
  await room.disconnect();
  await dispose();
}
process.exit(failure ? 1 : 0);
