#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN

// Control-thread helper: opt out of physical input streams (e.g. USB microphones).
OSStatus SoundcheckSelectIOStream(AudioObjectID device, AudioDeviceIOProcID proc,
                           AudioObjectPropertyScope scope, uint32_t streamIndex);

// The I/O thread only touches preallocated storage and lock-free atomics.
typedef struct SoundcheckRenderState SoundcheckRenderState;
SoundcheckRenderState * _Nullable SoundcheckRenderCreate(uint32_t inputBufferOffset, uint32_t outputBufferOffset,
                                uint32_t channels, bool planar, double sampleRate, float gain);
void SoundcheckRenderDestroy(SoundcheckRenderState *state);
void SoundcheckRenderSetGain(SoundcheckRenderState *state, float gain);
float SoundcheckRenderInputPeak(SoundcheckRenderState *state);
float SoundcheckRenderOutputPeak(SoundcheckRenderState *state);
void SoundcheckRenderSetVisualizing(SoundcheckRenderState *state, bool enabled);
void SoundcheckRenderReadTrace(SoundcheckRenderState *state, float *samples, uint32_t count);
uint64_t SoundcheckRenderCallbacks(SoundcheckRenderState *state);
uint32_t SoundcheckRenderFault(SoundcheckRenderState *state);
void SoundcheckRenderProcess(SoundcheckRenderState *state, const AudioBufferList *input, AudioBufferList *output);
OSStatus SoundcheckAudioIOProc(AudioObjectID device, const AudioTimeStamp *now,
                        const AudioBufferList *input, const AudioTimeStamp *inputTime,
                        AudioBufferList *output, const AudioTimeStamp *outputTime, void * _Nullable context);
OSStatus SoundcheckMeterIOProc(AudioObjectID device, const AudioTimeStamp *now,
                        const AudioBufferList *input, const AudioTimeStamp *inputTime,
                        AudioBufferList *output, const AudioTimeStamp *outputTime, void * _Nullable context);
CF_ASSUME_NONNULL_END
