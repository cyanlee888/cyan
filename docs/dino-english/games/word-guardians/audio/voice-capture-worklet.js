// Capture mono PCM on the audio rendering thread. Recognition runs in Vosk's worker.
class VoiceCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.samples = new Float32Array(512);
    this.offset = 0;
  }

  process(inputs, outputs) {
    // This node stays connected so processing continues, but never plays the mic back.
    for (const output of outputs) for (const channel of output) channel.fill(0);
    const channel = inputs[0]?.[0];
    if (!channel) return true;
    for (let index = 0; index < channel.length; index++) {
      this.samples[this.offset++] = channel[index];
      if (this.offset === this.samples.length) {
        this.port.postMessage(this.samples, [this.samples.buffer]);
        this.samples = new Float32Array(512);
        this.offset = 0;
      }
    }
    return true;
  }
}

registerProcessor('dino-voice-capture', VoiceCaptureProcessor);
