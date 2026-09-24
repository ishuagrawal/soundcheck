#include "RenderKernel.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stddef.h>

OSStatus SoundcheckSelectIOStream(AudioObjectID device, AudioDeviceIOProcID proc,
                           AudioObjectPropertyScope scope, uint32_t streamIndex) {
    AudioObjectPropertyAddress streams = { kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &streams, 0, NULL, &size);
    if (status) return status;
    UInt32 count = size / sizeof(AudioObjectID);
    if (streamIndex >= count) return kAudioHardwareBadStreamError;
    size = (UInt32)(offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32));
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = count;
    usage->mStreamIsOn[streamIndex] = 1;
    AudioObjectPropertyAddress property = { kAudioDevicePropertyIOProcStreamUsage, scope, kAudioObjectPropertyElementMain };
    status = AudioObjectSetPropertyData(device, &property, 0, NULL, size, usage);
    free(usage);
    return status;
}

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Audio atomics must be lock-free");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio counters must be lock-free");
_Static_assert(__atomic_always_lock_free(sizeof(float), 0), "Audio gain must be lock-free");

struct SoundcheckRenderState {
    uint32_t inputOffset, outputOffset, channels, rampLength;
    bool planar;
    _Atomic(float) target, inputPeak, outputPeak;
    _Atomic(uint64_t) callbacks;
    _Atomic(uint32_t) fault;
    _Atomic(bool) visualizing;
    _Atomic(float) trace[64];
    float history[256];
    uint32_t historyIndex;
    // Callback-owned ramp state. UI updates target atomically.
    float current, destination, increment;
    uint32_t remaining;
};

static float bounded(float x) { return isfinite(x) ? fminf(1, fmaxf(0, x)) : 1; }

SoundcheckRenderState *SoundcheckRenderCreate(uint32_t inOffset, uint32_t outOffset, uint32_t channels,
                                bool planar, double sampleRate, float gain) {
    if (!channels || channels > 32 || !isfinite(sampleRate) || sampleRate <= 0) return NULL;
    SoundcheckRenderState *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->inputOffset = inOffset; s->outputOffset = outOffset;
    s->channels = channels; s->planar = planar;
    s->rampLength = (uint32_t)fmax(1, sampleRate * .005); // 5 ms, independent of buffer size
    s->current = s->destination = bounded(gain);
    atomic_init(&s->target, s->current);
    atomic_init(&s->inputPeak, 0); atomic_init(&s->outputPeak, 0);
    atomic_init(&s->callbacks, 0); atomic_init(&s->fault, 0);
    atomic_init(&s->visualizing, false);
    for (uint32_t i = 0; i < 64; i++) atomic_init(&s->trace[i], 0);
    return s;
}
void SoundcheckRenderDestroy(SoundcheckRenderState *s) { free(s); }
void SoundcheckRenderSetGain(SoundcheckRenderState *s, float x) { atomic_store_explicit(&s->target, bounded(x), memory_order_relaxed); }
float SoundcheckRenderInputPeak(SoundcheckRenderState *s) { return atomic_load_explicit(&s->inputPeak, memory_order_relaxed); }
float SoundcheckRenderOutputPeak(SoundcheckRenderState *s) { return atomic_load_explicit(&s->outputPeak, memory_order_relaxed); }
void SoundcheckRenderSetVisualizing(SoundcheckRenderState *s, bool enabled) { atomic_store_explicit(&s->visualizing, enabled, memory_order_relaxed); }
void SoundcheckRenderReadTrace(SoundcheckRenderState *s, float *samples, uint32_t count) {
    for (uint32_t i = 0; i < count; i++) samples[i] = i < 64 ? atomic_load_explicit(&s->trace[i], memory_order_relaxed) : 0;
}
static void tracePush(SoundcheckRenderState *s, float sample) {
    s->history[s->historyIndex] = sample;
    s->historyIndex = (s->historyIndex + 1) % 256;
}
static void tracePublish(SoundcheckRenderState *s) {
    uint32_t start = s->historyIndex;
    // Trigger at a rising zero crossing to keep sustained tones visually stable.
    // Every point is an actual PCM sample; there is no synthesized oscillation.
    for (uint32_t i = 1; i < 128; i++) {
        uint32_t before = (s->historyIndex + i - 1) % 256;
        uint32_t after = (s->historyIndex + i) % 256;
        if (s->history[before] <= 0 && s->history[after] > 0) { start = after; break; }
    }
    for (uint32_t i = 0; i < 64; i++)
        atomic_store_explicit(&s->trace[i], s->history[(start + i * 2) % 256], memory_order_relaxed);
}
uint64_t SoundcheckRenderCallbacks(SoundcheckRenderState *s) { return atomic_load_explicit(&s->callbacks, memory_order_relaxed); }
uint32_t SoundcheckRenderFault(SoundcheckRenderState *s) { return atomic_load_explicit(&s->fault, memory_order_relaxed); }

void SoundcheckRenderProcess(SoundcheckRenderState *s, const AudioBufferList *input, AudioBufferList *output) {
    if (!s || !output) return;
    // HAL mixes this client's output with every other client's. Never reuse old output.
    for (uint32_t b = 0; b < output->mNumberBuffers; b++)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed);
    uint32_t count = s->planar ? s->channels : 1;
    if (!input || input->mNumberBuffers < s->inputOffset + count || output->mNumberBuffers < s->outputOffset + count) {
        atomic_store_explicit(&s->fault, 1, memory_order_relaxed); return;
    }
    uint32_t frames = UINT32_MAX;
    for (uint32_t b = 0; b < count; b++) {
        const AudioBuffer *in = &input->mBuffers[s->inputOffset + b];
        AudioBuffer *out = &output->mBuffers[s->outputOffset + b];
        uint32_t channels = s->planar ? 1 : s->channels;
        if (in->mNumberChannels != channels || out->mNumberChannels != channels) {
            atomic_store_explicit(&s->fault, 2, memory_order_relaxed); return;
        }
        // A nil input is a normal silent/paused stream. Do not dereference it.
        if (!in->mData || !out->mData) {
            atomic_store_explicit(&s->inputPeak, 0, memory_order_relaxed);
            atomic_store_explicit(&s->outputPeak, 0, memory_order_relaxed); return;
        }
        uint32_t inFrames = in->mDataByteSize / (sizeof(float) * channels);
        uint32_t outFrames = out->mDataByteSize / (sizeof(float) * channels);
        if (inFrames != outFrames) { atomic_store_explicit(&s->fault, 3, memory_order_relaxed); return; }
        if (inFrames < frames) frames = inFrames;
    }
    float target = atomic_load_explicit(&s->target, memory_order_relaxed);
    if (target != s->destination) {
        s->destination = target; s->remaining = s->rampLength;
        s->increment = (target - s->current) / s->rampLength;
    }
    float inPeak = 0, outPeak = 0;
    bool visualizing = atomic_load_explicit(&s->visualizing, memory_order_relaxed);
    for (uint32_t frame = 0; frame < frames; frame++) {
        if (s->remaining) {
            s->current += s->increment;
            if (!--s->remaining) s->current = s->destination;
        }
        float visualSample = 0;
        for (uint32_t channel = 0; channel < s->channels; channel++) {
            uint32_t b = s->planar ? channel : 0;
            uint32_t i = s->planar ? frame : frame * s->channels + channel;
            float x = ((const float *)input->mBuffers[s->inputOffset + b].mData)[i];
            if (!isfinite(x)) x = 0;
            float y = x * s->current;
            ((float *)output->mBuffers[s->outputOffset + b].mData)[i] = y;
            inPeak = fmaxf(inPeak, fabsf(x)); outPeak = fmaxf(outPeak, fabsf(y));
            if (visualizing && fabsf(y) > fabsf(visualSample)) visualSample = y;
        }
        if (visualizing) tracePush(s, visualSample);
    }
    if (visualizing) tracePublish(s);
    atomic_store_explicit(&s->inputPeak, inPeak, memory_order_relaxed);
    atomic_store_explicit(&s->outputPeak, outPeak, memory_order_relaxed);
}

OSStatus SoundcheckAudioIOProc(AudioObjectID device, const AudioTimeStamp *now,
                        const AudioBufferList *input, const AudioTimeStamp *inputTime,
                        AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    SoundcheckRenderProcess(context, input, output);
    return noErr;
}

OSStatus SoundcheckMeterIOProc(AudioObjectID device, const AudioTimeStamp *now,
                        const AudioBufferList *input, const AudioTimeStamp *inputTime,
                        AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    SoundcheckRenderState *s = context;
    if (!s || !input) return noErr;
    float peak = 0;
    for (uint32_t b = s->inputOffset; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        if (!buffer->mData) continue;
        const float *samples = buffer->mData;
        uint32_t count = buffer->mDataByteSize / sizeof(float);
        for (uint32_t i = 0; i < count; i++)
            if (isfinite(samples[i])) peak = fmaxf(peak, fabsf(samples[i]));
    }
    atomic_store_explicit(&s->inputPeak, peak, memory_order_relaxed);
    if (atomic_load_explicit(&s->visualizing, memory_order_relaxed) && input->mNumberBuffers > s->inputOffset) {
        uint32_t buffers = s->planar ? s->channels : 1;
        if (input->mNumberBuffers >= s->inputOffset + buffers) {
            uint32_t frames = UINT32_MAX;
            for (uint32_t b = 0; b < buffers; b++) {
                const AudioBuffer *buffer = &input->mBuffers[s->inputOffset + b];
                uint32_t stride = s->planar ? 1 : s->channels;
                uint32_t available = buffer->mData ? buffer->mDataByteSize / (sizeof(float) * stride) : 0;
                if (available < frames) frames = available;
            }
            for (uint32_t frame = 0; frame < frames; frame++) {
                float value = 0;
                for (uint32_t channel = 0; channel < s->channels; channel++) {
                    uint32_t b = s->planar ? channel : 0;
                    uint32_t i = s->planar ? frame : frame * s->channels + channel;
                    float sample = ((const float *)input->mBuffers[s->inputOffset + b].mData)[i];
                    if (isfinite(sample) && fabsf(sample) > fabsf(value)) value = sample;
                }
                tracePush(s, value);
            }
            if (!frames) for (uint32_t i = 0; i < 256; i++) tracePush(s, 0);
            tracePublish(s);
        }
    }
    atomic_fetch_add_explicit(&s->callbacks, 1, memory_order_relaxed);
    return noErr;
}
