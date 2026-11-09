// Apiko's machine voice and effects: port of bridge\apiko_dsp.py (monotone "AI voice" processing) and of the
// effects in apiko_voice.Voice (the pedalboard chain, ring modulation, glitches).
// The synthetic quality comes from the melody: the pitch is tracked (YIN), flattened towards its median and snapped
// to semitones, then re-pitched with TD-PSOLA; breaths are muted, loudness evened out, and a quiet copy an octave up
// is mixed in. The effects (filters, chorus, bit crush, distortion, ring modulation) grow with instability.
// The pedalboard plugins are re-implemented the way JUCE does them (first-order filters, juce::dsp::Chorus,
// tanh waveshaper); pedalboard's PitchShift is only ever used at 0 semitones there, so it is left out.
#pragma once

#include <random>
#include <vector>

namespace apiko::dsp
{
using Samples = std::vector<float>;

struct Style
{
    double keep = 0.0;       // share of the original melody kept
    double semitones = 1.5;  // shift of the whole voice
    bool steps = true;       // snap the melody to whole semitones
    bool removeBreaths = true;
    double level = 0.8;      // how much loudness is evened out
    double octaveMix = 0.15; // the copy one octave up
};

// f0 in Hz per hop (0 = unvoiced), and the hop size in samples.
std::vector<double> PitchTrack(const std::vector<double>& aX, int aRate, int& aHop);

// The full flat "AI" treatment of speech.
Samples MachineVoice(const Samples& aX, int aRate, const Style& aStyle);

// Effects that destabilize with instability (0..1), normalized to aVolume at the peak.
Samples Effects(const Samples& aAudio, int aRate, double aInstability, double aVolume);

// Dropouts and stutters inside the speech; none below 0.35 instability.
Samples RandomGlitches(Samples aSamples, int aRate, double aInstability, std::mt19937& aRandom);

// The sound of a glitch token in the text: a stutter of the last sound, static or a dropout.
Samples GlitchSound(const Samples* aPrevious, int aRate, double aInstability, std::mt19937& aRandom);

// A phone line's band (450 Hz - 3 kHz), normalized to aVolume at the peak.
Samples PhoneLine(const Samples& aAudio, int aRate, double aVolume);
} // namespace apiko::dsp
