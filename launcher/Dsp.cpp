#include "Dsp.hpp"

#include <algorithm>
#include <cmath>
#include <numbers>

namespace apiko::dsp
{
namespace
{
constexpr double HopSeconds = 0.005;
constexpr double FMin = 70.0;
constexpr double FMax = 600.0;
constexpr double YinThreshold = 0.15;
// Breaths: unvoiced stretches at least this long can be breaths (fricatives are shorter); only their frames quieter
// than BreathLevel of the voiced level are muted, down to BreathFloor.
constexpr double BreathMinSeconds = 0.12;
constexpr double BreathLevel = 0.2;
constexpr double BreathFloor = 0.03;
constexpr double RampSeconds = 0.008;
constexpr double Pi = std::numbers::pi;

using Signal = std::vector<double>;

double Median(std::vector<double> aValues)
{
    if (aValues.empty())
        return 0.0;
    auto middle = aValues.size() / 2;
    std::nth_element(aValues.begin(), aValues.begin() + middle, aValues.end());
    double upper = aValues[middle];
    if (aValues.size() % 2)
        return upper;
    double lower = *std::max_element(aValues.begin(), aValues.begin() + middle);
    return 0.5 * (lower + upper);
}

// np.convolve(x, np.ones(k) / k, mode="same"): output i averages x[i - k/2 .. i + (k-1)/2] (zeros outside).
Signal MovingAverage(const Signal& aX, std::size_t aSize)
{
    auto n = aX.size();
    Signal prefix(n + 1, 0.0);
    for (std::size_t i = 0; i < n; ++i)
        prefix[i + 1] = prefix[i] + aX[i];
    Signal out(n);
    auto back = static_cast<std::ptrdiff_t>(aSize / 2);
    auto ahead = static_cast<std::ptrdiff_t>((aSize - 1) / 2);
    for (std::size_t i = 0; i < n; ++i)
    {
        auto lo = std::max<std::ptrdiff_t>(0, static_cast<std::ptrdiff_t>(i) - back);
        auto hi = std::min<std::ptrdiff_t>(static_cast<std::ptrdiff_t>(n), static_cast<std::ptrdiff_t>(i) + ahead + 1);
        out[i] = (prefix[hi] - prefix[lo]) / static_cast<double>(aSize);
    }
    return out;
}

Signal ToSignal(const Samples& aX)
{
    return Signal(aX.begin(), aX.end());
}

Samples ToSamples(const Signal& aX)
{
    Samples out(aX.size());
    std::transform(aX.begin(), aX.end(), out.begin(), [](double v) { return static_cast<float>(v); });
    return out;
}

// Target pitch per hop: deviations from the median scaled by aKeep, snapped to semitones, shifted.
std::vector<double> FlattenPitch(const std::vector<double>& aF0, double aKeep, double aSemitones, bool aSteps)
{
    std::vector<double> voicedLog;
    for (double f : aF0)
        if (f > 0)
            voicedLog.push_back(std::log2(f) * 12.0);
    if (voicedLog.empty())
        return aF0;
    double centre = Median(voicedLog);
    std::vector<double> target(aF0.size(), 0.0);
    for (std::size_t i = 0; i < aF0.size(); ++i)
    {
        if (aF0[i] <= 0)
            continue;
        double semis = centre + (std::log2(aF0[i]) * 12.0 - centre) * aKeep;
        if (aSteps)
            semis = centre + std::nearbyint(semis - centre);
        target[i] = std::pow(2.0, (semis + aSemitones) / 12.0);
    }
    return target;
}

// Gain per sample that mutes breaths: long, quiet, unvoiced stretches. Loud fricatives (s, f, j) stay.
Signal BreathGate(const Signal& aX, int aRate, const std::vector<double>& aF0, int aHop)
{
    auto count = aF0.size();
    std::vector<double> rms(count);
    for (std::size_t i = 0; i < count; ++i)
    {
        double sum = 0;
        for (std::size_t j = i * aHop; j < i * aHop + 2 * aHop; ++j)
            if (j < aX.size())
                sum += aX[j] * aX[j];
        rms[i] = std::sqrt(sum / (2.0 * aHop));
    }
    std::vector<double> voicedRms;
    for (std::size_t i = 0; i < count; ++i)
        if (aF0[i] > 0)
            voicedRms.push_back(rms[i]);
    if (voicedRms.empty())
        return Signal(aX.size(), 1.0);
    double reference = Median(voicedRms);
    std::vector<double> gain(count, 1.0);
    auto minFrames = static_cast<std::size_t>(BreathMinSeconds / HopSeconds);
    for (std::size_t i = 0; i < count;)
    {
        if (aF0[i] > 0)
        {
            ++i;
            continue;
        }
        auto j = i;
        while (j < count && aF0[j] <= 0)
            ++j;
        if (j - i >= minFrames)
            for (auto k = i; k < j; ++k)
                if (rms[k] < reference * BreathLevel)
                    gain[k] = BreathFloor;
        i = j;
    }
    // Per sample, with short ramps so the cuts do not click.
    Signal perSample(aX.size());
    for (std::size_t i = 0; i < aX.size(); ++i)
        perSample[i] = gain[std::min(count - 1, i / aHop)];
    return MovingAverage(perSample, std::max(1, static_cast<int>(aRate * RampSeconds)));
}

// Evens out loudness (no stressed syllables): each moment is pulled towards the median speech level.
Signal Level(const Signal& aX, int aRate, double aAmount, double aWindowSeconds = 0.03)
{
    auto size = std::max<std::size_t>(1, static_cast<std::size_t>(aRate * aWindowSeconds));
    Signal squares(aX.size());
    for (std::size_t i = 0; i < aX.size(); ++i)
        squares[i] = aX[i] * aX[i];
    auto envelope = MovingAverage(squares, size);
    double top = 0;
    for (auto& e : envelope)
    {
        e = std::sqrt(std::max(0.0, e));
        top = std::max(top, e);
    }
    std::vector<double> speech;
    for (double e : envelope)
        if (e > top * 0.05)
            speech.push_back(e);
    if (speech.empty())
        return aX;
    double target = Median(speech);
    Signal gain(aX.size());
    for (std::size_t i = 0; i < aX.size(); ++i)
        gain[i] = envelope[i] > top * 0.05
                      ? std::clamp(std::pow(target / std::max(envelope[i], 1e-9), aAmount), 0.25, 4.0)
                      : 1.0;
    gain = MovingAverage(gain, size); // no zipper noise
    Signal out(aX.size());
    for (std::size_t i = 0; i < aX.size(); ++i)
        out[i] = aX[i] * gain[i];
    return out;
}

// Re-pitches speech towards a flat, stepped machine melody, optionally muting breaths.
Signal Monotone(Signal aX, int aRate, double aKeep, double aSemitones, bool aSteps, bool aRemoveBreaths)
{
    if (aX.size() < static_cast<std::size_t>(aRate / 10))
        return aX;
    int hop = 0;
    auto f0 = PitchTrack(aX, aRate, hop);
    if (aRemoveBreaths)
    {
        auto gate = BreathGate(aX, aRate, f0, hop);
        for (std::size_t i = 0; i < aX.size(); ++i)
            aX[i] *= gate[i];
    }
    auto target = FlattenPitch(f0, aKeep, aSemitones, aSteps);
    auto at = [hop](const std::vector<double>& aTrack, double aT) {
        return aTrack[std::min(aTrack.size() - 1, static_cast<std::size_t>(aT / hop))];
    };
    auto n = aX.size();

    // Analysis marks: one per period in voiced parts (snapped to the local peak), one per hop elsewhere.
    std::vector<std::ptrdiff_t> marks, periods;
    auto smooth = MovingAverage(aX, 5);
    for (std::ptrdiff_t t = 0; t < static_cast<std::ptrdiff_t>(n);)
    {
        double f = at(f0, static_cast<double>(t));
        if (f > 0)
        {
            auto period = static_cast<std::ptrdiff_t>(aRate / f);
            auto lo = std::max<std::ptrdiff_t>(0, t - period / 4);
            auto hi = std::min<std::ptrdiff_t>(static_cast<std::ptrdiff_t>(n), t + period / 4 + 1);
            auto peak = t;
            if (hi > lo)
            {
                peak = lo;
                for (auto k = lo; k < hi; ++k)
                    if (std::abs(smooth[k]) > std::abs(smooth[peak]))
                        peak = k;
            }
            if (!marks.empty() && peak <= marks.back())
                peak = marks.back() + std::max<std::ptrdiff_t>(1, period / 2);
            marks.push_back(peak);
            periods.push_back(period);
            t = peak + period;
        }
        else
        {
            marks.push_back(t);
            periods.push_back(hop);
            t += hop;
        }
    }

    Signal out(n + 2 * aRate / 10, 0.0);
    Signal norm(out.size(), 0.0);
    double tOut = static_cast<double>(marks[0]);
    while (tOut < static_cast<double>(n))
    {
        // The nearest mark (marks only grow; ties go to the earlier one, like np.argmin).
        auto upper = std::lower_bound(marks.begin(), marks.end(), static_cast<std::ptrdiff_t>(std::ceil(tOut)));
        std::size_t i = upper == marks.end() ? marks.size() - 1 : static_cast<std::size_t>(upper - marks.begin());
        if (i > 0 && std::abs(marks[i - 1] - tOut) <= std::abs(marks[i] - tOut))
            i -= 1;
        auto centre = marks[i];
        auto period = periods[i];
        auto lo = centre - period;
        auto hi = centre + period;
        if (lo >= 0 && hi <= static_cast<std::ptrdiff_t>(n))
        {
            auto length = hi - lo;
            auto start = static_cast<std::ptrdiff_t>(std::nearbyint(tOut)) - period;
            if (start >= 0)
                for (std::ptrdiff_t k = 0; k < length && start + k < static_cast<std::ptrdiff_t>(out.size()); ++k)
                {
                    // np.hanning(length)
                    double window = length > 1 ? 0.5 - 0.5 * std::cos(2.0 * Pi * k / (length - 1)) : 1.0;
                    out[start + k] += aX[lo + k] * window;
                    norm[start + k] += window;
                }
        }
        double f = at(target, static_cast<double>(marks[i]));
        tOut += f > 0 ? aRate / f : static_cast<double>(period);
    }
    out.resize(n);
    for (std::size_t i = 0; i < n; ++i)
        out[i] /= std::max(norm[i], 0.5);
    return out;
}

double Uniform(std::mt19937& aRandom, double aLo, double aHi)
{
    return std::uniform_real_distribution<double>(aLo, aHi)(aRandom);
}

Samples Static(int aRate, double aSeconds, std::mt19937& aRandom)
{
    auto n = static_cast<std::size_t>(aRate * aSeconds);
    Signal noise(n);
    for (auto& v : noise)
        v = Uniform(aRandom, -1.0, 1.0);
    // Crude band limit (moving average) and a fade so it doesn't click.
    noise = MovingAverage(noise, 4);
    Samples out(n);
    for (std::size_t i = 0; i < n; ++i)
    {
        double envelope = std::min(1.0, static_cast<double>(std::min(i, n - 1 - i)) / (aRate * 0.01));
        out[i] = static_cast<float>(noise[i] * envelope * 0.18);
    }
    return out;
}

// First-order filters as JUCE's IIR::Coefficients::makeFirstOrderLowPass / HighPass (pedalboard's filters).
void FirstOrder(Signal& aX, int aRate, double aCutoff, bool aHighPass)
{
    double n = std::tan(Pi * aCutoff / aRate);
    double b0 = aHighPass ? 1.0 / (n + 1.0) : n / (n + 1.0);
    double b1 = aHighPass ? -b0 : b0;
    double a1 = (n - 1.0) / (n + 1.0);
    double x1 = 0, y1 = 0;
    for (auto& v : aX)
    {
        double y = b0 * v + b1 * x1 - a1 * y1;
        x1 = v;
        y1 = y;
        v = y;
    }
}

// juce::dsp::Chorus: a delay modulated by a sine LFO around the centre delay (up to 20 ms * depth / 2 either way),
// with feedback, mixed linearly with the dry signal.
void Chorus(Signal& aX, int aRate, double aRateHz, double aDepth, double aCentreMs, double aFeedback, double aMix)
{
    std::vector<double> line(static_cast<std::size_t>(aRate * 0.1) + 4, 0.0);
    std::size_t write = 0;
    double lastOutput = 0.0;
    for (std::size_t i = 0; i < aX.size(); ++i)
    {
        double lfo = std::sin(2.0 * Pi * aRateHz * i / aRate) * aDepth * 0.5;
        double delayMs = std::max(1.0, 20.0 * lfo + aCentreMs);
        double delay = delayMs * aRate / 1000.0;
        double input = aX[i];
        line[write] = input - lastOutput;
        // Linear interpolation, delay samples behind the write position.
        double readAt = static_cast<double>(write) - delay;
        while (readAt < 0)
            readAt += static_cast<double>(line.size());
        auto j = static_cast<std::size_t>(readAt);
        double frac = readAt - j;
        double wet = line[j % line.size()] * (1.0 - frac) + line[(j + 1) % line.size()] * frac;
        lastOutput = wet * aFeedback;
        write = (write + 1) % line.size();
        aX[i] = input * (1.0 - aMix) + wet * aMix;
    }
}

Samples Normalize(const Signal& aX, double aVolume)
{
    double peak = 0;
    for (double v : aX)
        peak = std::max(peak, std::abs(v));
    double gain = aVolume / (peak > 0 ? peak : 1.0);
    Samples out(aX.size());
    for (std::size_t i = 0; i < aX.size(); ++i)
        out[i] = static_cast<float>(aX[i] * gain);
    return out;
}
} // namespace

std::vector<double> PitchTrack(const std::vector<double>& aX, int aRate, int& aHop)
{
    int hop = static_cast<int>(aRate * HopSeconds);
    aHop = hop;
    int tauMin = static_cast<int>(aRate / FMax);
    int tauMax = static_cast<int>(aRate / FMin);
    int width = tauMax; // integration window
    int span = width + tauMax;
    auto n = aX.size();
    std::size_t count = std::max<std::size_t>(1, n == 0 ? 1 : (n - 1) / hop + 1);
    auto sample = [&](std::size_t aIndex) { return aIndex < n ? aX[aIndex] : 0.0; };

    std::vector<double> energy0(count);
    std::vector<std::vector<double>> cmnd(count);
    for (std::size_t i = 0; i < count; ++i)
    {
        auto start = i * hop;
        std::vector<double> frame(span);
        for (int k = 0; k < span; ++k)
            frame[k] = sample(start + k);
        double e0 = 0;
        for (int j = 0; j < width; ++j)
            e0 += frame[j] * frame[j];
        energy0[i] = e0;
        // Difference function d(tau) = sum_j (x_j - x_{j+tau})^2 over the window, then its cumulative mean
        // normalised form.
        auto& row = cmnd[i];
        row.assign(tauMax + 1, 1.0);
        double cumulative = 0;
        for (int tau = 1; tau <= tauMax; ++tau)
        {
            double d = 0;
            for (int j = 0; j < width; ++j)
            {
                double diff = frame[j] - frame[j + tau];
                d += diff * diff;
            }
            cumulative += d;
            row[tau] = d * tau / std::max(cumulative, 1e-12);
        }
    }
    double loudest = *std::max_element(energy0.begin(), energy0.end());
    std::vector<double> f0(count, 0.0);
    for (std::size_t i = 0; i < count; ++i)
    {
        if (!(energy0[i] > loudest * 1e-3))
            continue;
        const auto& row = cmnd[i];
        int tau = -1;
        for (int t = tauMin; t <= tauMax; ++t)
            if (row[t] < YinThreshold)
            {
                tau = t;
                break;
            }
        if (tau < 0)
            continue;
        while (tau + 1 <= tauMax && row[tau + 1] < row[tau])
            ++tau;
        double refined = tau;
        if (tau > 0 && tau < tauMax) // parabolic refinement
        {
            double a = row[tau - 1], b = row[tau], c = row[tau + 1];
            double denominator = a - 2 * b + c;
            double shift = denominator != 0 ? 0.5 * (a - c) / denominator : 0.0;
            refined = tau + std::clamp(shift, -1.0, 1.0);
        }
        f0[i] = aRate / refined;
    }
    // Drop single-hop voiced blips and fill single-hop gaps.
    std::vector<bool> voiced(count);
    for (std::size_t i = 0; i < count; ++i)
        voiced[i] = f0[i] > 0;
    for (std::size_t i = 1; i + 1 < count; ++i)
    {
        if (voiced[i] && !voiced[i - 1] && !voiced[i + 1])
            f0[i] = 0.0;
        else if (!voiced[i] && voiced[i - 1] && voiced[i + 1])
            f0[i] = 0.5 * (f0[i - 1] + f0[i + 1]);
    }
    return f0;
}

Samples MachineVoice(const Samples& aX, int aRate, const Style& aStyle)
{
    auto voice = Monotone(ToSignal(aX), aRate, aStyle.keep, aStyle.semitones, aStyle.steps, aStyle.removeBreaths);
    if (aStyle.octaveMix > 0)
    {
        auto upper = Monotone(voice, aRate, 0.0, 12.0, false, false);
        for (std::size_t i = 0; i < voice.size(); ++i)
            voice[i] = voice[i] * (1.0 - aStyle.octaveMix) + upper[i] * aStyle.octaveMix;
    }
    if (aStyle.level > 0)
        voice = Level(voice, aRate, aStyle.level);
    return ToSamples(voice);
}

Samples Effects(const Samples& aAudio, int aRate, double aInstability, double aVolume)
{
    auto x = ToSignal(aAudio);
    FirstOrder(x, aRate, 220.0, true);
    FirstOrder(x, aRate, 7500.0 - 3000.0 * aInstability, false);
    Chorus(x, aRate, 0.9, 0.15, 6.0, 0.1, 0.25);
    // Bitcrush: quantized to 2^bits steps.
    double scale = std::pow(2.0, std::max(6.0, 14.0 - 8.0 * aInstability));
    for (auto& v : x)
        v = std::nearbyint(v * scale) / scale;
    // Distortion: gain then tanh.
    double drive = std::pow(10.0, (1.0 + 12.0 * aInstability) / 20.0);
    for (auto& v : x)
        v = std::tanh(v * drive);
    // Ring modulation: the classic metallic robot timbre, mixed in more as Apiko destabilises.
    double mix = 0.1 + 0.35 * aInstability;
    for (std::size_t i = 0; i < x.size(); ++i)
        x[i] = x[i] * (1.0 - mix) + x[i] * std::sin(2.0 * Pi * 55.0 * i / aRate) * mix;
    return Normalize(x, aVolume);
}

Samples RandomGlitches(Samples aSamples, int aRate, double aInstability, std::mt19937& aRandom)
{
    if (aInstability < 0.35 || aSamples.size() < static_cast<std::size_t>(aRate / 2))
        return aSamples;
    std::poisson_distribution<int> events((aInstability - 0.3) * 1.2 * aSamples.size() / aRate);
    int count = events(aRandom);
    for (int e = 0; e < count; ++e)
    {
        auto start = std::uniform_int_distribution<std::size_t>(0, aSamples.size() - aRate / 5)(aRandom);
        auto length = static_cast<std::size_t>(aRate * Uniform(aRandom, 0.04, 0.12));
        auto end = std::min(aSamples.size(), start + length);
        if (Uniform(aRandom, 0.0, 1.0) < 0.5)
            std::fill(aSamples.begin() + start, aSamples.begin() + end, 0.0f);
        else
        {
            Samples chunk(aSamples.begin() + start, aSamples.begin() + end);
            aSamples.insert(aSamples.begin() + end, chunk.begin(), chunk.end());
            aSamples.insert(aSamples.begin() + end, chunk.begin(), chunk.end());
        }
    }
    return aSamples;
}

Samples GlitchSound(const Samples* aPrevious, int aRate, double aInstability, std::mt19937& aRandom)
{
    double choice = Uniform(aRandom, 0.0, 1.0);
    if (aPrevious && aPrevious->size() > static_cast<std::size_t>(aRate / 10) && choice < 0.4)
    {
        // Stutter: the end of the last sound, repeated.
        auto length = std::min(aPrevious->size(), static_cast<std::size_t>(aRate * Uniform(aRandom, 0.05, 0.09)));
        Samples chunk(aPrevious->end() - length, aPrevious->end());
        Samples out;
        for (int r = std::uniform_int_distribution<int>(2, 4)(aRandom); r > 0; --r)
            out.insert(out.end(), chunk.begin(), chunk.end());
        return out;
    }
    if (choice < 0.75)
        return Static(aRate, Uniform(aRandom, 0.08, 0.2 + 0.15 * aInstability), aRandom);
    return Samples(static_cast<std::size_t>(aRate * Uniform(aRandom, 0.06, 0.15)), 0.0f);
}

Samples PhoneLine(const Samples& aAudio, int aRate, double aVolume)
{
    auto x = ToSignal(aAudio);
    FirstOrder(x, aRate, 450.0, true);
    FirstOrder(x, aRate, 3000.0, false);
    return Normalize(x, aVolume);
}
} // namespace apiko::dsp
