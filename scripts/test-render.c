#include "../Soundcheck/Audio/RenderKernel.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { UInt32 mNumberBuffers; AudioBuffer mBuffers[4]; } Buffers;
static void closeTo(float actual, float expected) { assert(fabsf(actual - expected) < .0001f); }

int main(void) {
    float source[1024], output[1024], mic[1024], unused[1024];
    for (int i = 0; i < 1024; i++) { source[i] = (i % 2 ? -.6f : .8f); mic[i] = 1; output[i] = 8; unused[i] = 8; }
    Buffers input = {2, {{2, sizeof(mic), mic}, {2, sizeof(source), source}}};
    Buffers destination = {2, {{2, sizeof(output), output}, {2, sizeof(unused), unused}}};
    SoundcheckRenderState *s = SoundcheckRenderCreate(1, 0, 2, false, 48000, .5f);
    assert(s);
    SoundcheckRenderProcess(s, (AudioBufferList *)&input, (AudioBufferList *)&destination);
    for (int i = 0; i < 1024; i++) { closeTo(output[i], source[i] * .5f); closeTo(unused[i], 0); }
    closeTo(SoundcheckRenderInputPeak(s), .8f); closeTo(SoundcheckRenderOutputPeak(s), .4f);
    assert(SoundcheckRenderFault(s) == 0);
    puts("PASS stereo gain and input offset (microphone excluded)");

    SoundcheckRenderSetGain(s, 0);
    SoundcheckRenderProcess(s, (AudioBufferList *)&input, (AudioBufferList *)&destination);
    assert(output[0] > 0 && output[0] < .4f);
    for (int i = 480; i < 1024; i++) closeTo(output[i], 0);
    for (int i = 2; i < 480; i += 2) assert(output[i] <= output[i - 2]);
    puts("PASS mute ramps monotonically to exact zero in 5ms");

    SoundcheckRenderSetGain(s, 1);
    SoundcheckRenderProcess(s, (AudioBufferList *)&input, (AudioBufferList *)&destination);
    for (int i = 480; i < 1024; i++) closeTo(output[i], source[i]);
    source[1000] = NAN; source[1001] = INFINITY;
    SoundcheckRenderProcess(s, (AudioBufferList *)&input, (AudioBufferList *)&destination);
    closeTo(output[1000], 0); closeTo(output[1001], 0);
    puts("PASS unmute and nonfinite sample handling");

    input.mBuffers[1].mData = NULL;
    SoundcheckRenderProcess(s, (AudioBufferList *)&input, (AudioBufferList *)&destination);
    for (int i = 0; i < 1024; i++) closeTo(output[i], 0);
    assert(SoundcheckRenderFault(s) == 0);
    input.mBuffers[1].mData = source;
    input.mBuffers[1].mNumberChannels = 1;
    SoundcheckRenderProcess(s, (AudioBufferList *)&input, (AudioBufferList *)&destination);
    assert(SoundcheckRenderFault(s) == 2);
    for (int i = 0; i < 1024; i++) closeTo(output[i], 0);
    puts("PASS silent input and fail-safe channel-layout rejection");
    SoundcheckRenderDestroy(s);

    float left[512], right[512], leftOut[512], rightOut[512];
    for (int i = 0; i < 512; i++) { left[i] = .7f; right[i] = -.3f; }
    Buffers planarIn = {2, {{1, sizeof(left), left}, {1, sizeof(right), right}}};
    Buffers planarOut = {3, {{1, sizeof(unused), unused}, {1, sizeof(leftOut), leftOut}, {1, sizeof(rightOut), rightOut}}};
    s = SoundcheckRenderCreate(0, 1, 2, true, 44100, .25f);
    SoundcheckRenderProcess(s, (AudioBufferList *)&planarIn, (AudioBufferList *)&planarOut);
    for (int i = 0; i < 512; i++) { closeTo(leftOut[i], .175f); closeTo(rightOut[i], -.075f); }
    assert(SoundcheckRenderFault(s) == 0);
    puts("PASS planar stereo, channel separation, output buffer offset");
    SoundcheckRenderDestroy(s);

    // Two independently controlled clients must never share gain state.
    SoundcheckRenderState *a = SoundcheckRenderCreate(0, 0, 1, false, 48000, .2f);
    SoundcheckRenderState *b = SoundcheckRenderCreate(0, 0, 1, false, 48000, .8f);
    Buffers monoIn = {1, {{1, sizeof(left), left}}};
    Buffers monoA = {1, {{1, sizeof(leftOut), leftOut}}};
    Buffers monoB = {1, {{1, sizeof(rightOut), rightOut}}};
    SoundcheckRenderProcess(a, (AudioBufferList *)&monoIn, (AudioBufferList *)&monoA);
    SoundcheckRenderProcess(b, (AudioBufferList *)&monoIn, (AudioBufferList *)&monoB);
    closeTo(leftOut[511], .14f); closeTo(rightOut[511], .56f);
    SoundcheckRenderDestroy(a); SoundcheckRenderDestroy(b);
    assert(SoundcheckRenderCreate(0, 0, 0, false, 48000, 1) == NULL);
    assert(SoundcheckRenderCreate(0, 0, 2, false, NAN, 1) == NULL);
    puts("PASS independent client gains and invalid configuration rejection");
    // The visual trace must contain captured post-gain PCM, then become silent.
    s = SoundcheckRenderCreate(0, 0, 1, false, 48000, .5f);
    SoundcheckRenderSetVisualizing(s, true);
    for (int i = 0; i < 512; i++) left[i] = .5f * sinf((float)i * 2 * 3.14159265f / 48);
    SoundcheckRenderProcess(s, (AudioBufferList *)&monoIn, (AudioBufferList *)&monoA);
    float trace[64];
    SoundcheckRenderReadTrace(s, trace, 64);
    bool positive = false, negative = false;
    for (int i = 0; i < 64; i++) {
        assert(isfinite(trace[i]) && fabsf(trace[i]) <= .2501f);
        positive |= trace[i] > .1f; negative |= trace[i] < -.1f;
    }
    assert(positive && negative);
    SoundcheckRenderSetGain(s, 0);
    SoundcheckRenderProcess(s, (AudioBufferList *)&monoIn, (AudioBufferList *)&monoA);
    SoundcheckRenderProcess(s, (AudioBufferList *)&monoIn, (AudioBufferList *)&monoA);
    SoundcheckRenderReadTrace(s, trace, 64);
    for (int i = 0; i < 64; i++) closeTo(trace[i], 0);
    SoundcheckRenderDestroy(s);
    puts("PASS captured PCM trace follows gain and becomes silent on mute");

    // Meter-only traces preserve right-channel-only audio and sanitize NaNs.
    s = SoundcheckRenderCreate(0, 0, 2, false, 48000, 1);
    SoundcheckRenderSetVisualizing(s, true);
    for (int i = 0; i < 512; i++) { source[i * 2] = NAN; source[i * 2 + 1] = left[i]; }
    Buffers meterIn = {1, {{2, sizeof(source), source}}};
    AudioTimeStamp timestamp = {0};
    AudioBufferList noOutput = {0};
    SoundcheckMeterIOProc(0, &timestamp, (AudioBufferList *)&meterIn, &timestamp, &noOutput, &timestamp, s);
    SoundcheckRenderReadTrace(s, trace, 64);
    positive = false; negative = false;
    for (int i = 0; i < 64; i++) {
        assert(isfinite(trace[i]) && fabsf(trace[i]) <= .5001f);
        positive |= trace[i] > .1f; negative |= trace[i] < -.1f;
    }
    assert(positive && negative);
    SoundcheckRenderDestroy(s);
    puts("PASS meter trace captures right-only audio without nonfinite samples");
    return 0;
}
