// Applies the native machine voice and effects to a WAV, to compare by ear with the Python bridge's.
// Usage: dsp_wav <in.wav: 16-bit mono 24 kHz, plain speech> <out.wav> <instability> [glitch seed]
// The style is the catalog's default (keep 0, +1.5 semitones, steps, no breaths, level 0.8, octave 0.15).
#include "../Dsp.hpp"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <vector>

int main(int argc, char** argv)
{
    if (argc < 4)
    {
        std::cerr << "usage: dsp_wav <in.wav> <out.wav> <instability> [seed]\n";
        return 2;
    }
    std::ifstream in(argv[1], std::ios::binary);
    std::string raw((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    auto data = raw.find("data");
    if (raw.size() < 44 || data == std::string::npos)
    {
        std::cerr << "not a WAV\n";
        return 1;
    }
    std::vector<float> samples((raw.size() - data - 8) / 2);
    for (std::size_t i = 0; i < samples.size(); ++i)
    {
        std::int16_t v;
        std::memcpy(&v, raw.data() + data + 8 + i * 2, 2);
        samples[i] = v / 32768.0f;
    }
    double instability = std::atof(argv[3]);
    std::mt19937 random(argc > 4 ? std::atoi(argv[4]) : 1);
    auto speech = apiko::dsp::RandomGlitches(apiko::dsp::MachineVoice(samples, 24000, {}), 24000, instability, random);
    auto out = apiko::dsp::Effects(speech, 24000, instability, 0.8);

    std::ofstream file(argv[2], std::ios::binary);
    auto put32 = [&](std::uint32_t v) { file.write(reinterpret_cast<const char*>(&v), 4); };
    auto put16 = [&](std::uint16_t v) { file.write(reinterpret_cast<const char*>(&v), 2); };
    auto bytes = static_cast<std::uint32_t>(out.size() * 2);
    file.write("RIFF", 4);
    put32(36 + bytes);
    file.write("WAVEfmt ", 8);
    put32(16);
    put16(1);
    put16(1);
    put32(24000);
    put32(48000);
    put16(2);
    put16(16);
    file.write("data", 4);
    put32(bytes);
    for (float v : out)
        put16(static_cast<std::uint16_t>(static_cast<std::int16_t>(std::max(-1.0f, std::min(1.0f, v)) * 32767)));
    std::cout << "wrote " << argv[2] << " (" << out.size() / 24000.0 << " s)\n";
    return 0;
}
