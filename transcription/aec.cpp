// Offline PCM processor. No audio devices, NS, or AGC; inputs are validated by echo_cancellation.py.
#include "api/audio/audio_processing.h"
#include "api/audio/echo_canceller3_config.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"
#include <algorithm>
#include <array>
#include <cstdio>
#include <fstream>
#include <stdexcept>

class Factory final : public webrtc::EchoControlFactory {
 public:
  std::unique_ptr<webrtc::EchoControl> Create(int rate, int render, int capture) override {
    webrtc::EchoCanceller3Config cfg;
    cfg.filter.export_linear_aec_output = true;
    // Same soft tuning as the real-recording experiment; keep word onsets during double talk.
    cfg.suppressor.dominant_nearend_detection.enr_threshold = .75f;
    cfg.suppressor.dominant_nearend_detection.trigger_threshold = 1;
    cfg.suppressor.dominant_nearend_detection.snr_threshold = 10.f;
    cfg.suppressor.normal_tuning.mask_lf.enr_transparent = .4f;
    cfg.suppressor.normal_tuning.mask_lf.enr_suppress = .5f;
    cfg.suppressor.nearend_tuning.mask_lf.enr_transparent = 2.f;
    cfg.suppressor.nearend_tuning.mask_lf.enr_suppress = 2.1f;
    cfg.suppressor.nearend_tuning.mask_hf.enr_transparent = .3f;
    cfg.suppressor.nearend_tuning.mask_hf.enr_suppress = .5f;
    if (!webrtc::EchoCanceller3Config::Validate(&cfg)) throw std::runtime_error("Invalid AEC3 config");
    return std::make_unique<webrtc::EchoCanceller3>(cfg, std::nullopt, rate, render, capture);
  }
};

int main(int argc, char** argv) {
  if (argc != 6) return 2;
  try {
    std::ifstream host(argv[1], std::ios::binary), remote(argv[2], std::ios::binary);
    host.seekg(std::stoull(argv[3])); remote.seekg(std::stoull(argv[4]));
    const auto frames = std::stoull(argv[5]);
    if (!host || !remote || !frames) throw std::runtime_error("Invalid PCM input");
    webrtc::AudioProcessing::Config cfg;
    cfg.echo_canceller.enabled = true;
    cfg.echo_canceller.export_linear_aec_output = true;
    cfg.noise_suppression.enabled = false;
    cfg.gain_controller1.enabled = false;
    cfg.gain_controller2.enabled = false;
    webrtc::AudioProcessingBuilder builder;
    builder.SetConfig(cfg);
    builder.SetEchoControlFactory(std::make_unique<Factory>());
    auto apm = builder.Create();
    if (!apm) throw std::runtime_error("Cannot create AEC3");
    webrtc::StreamConfig format(16000, 1);
    std::array<int16_t, 160> mic, far, output, scratch;
    for (uint64_t done = 0; done < frames; done += 160) {
      auto count = std::min<uint64_t>(160, frames - done);
      mic.fill(0); far.fill(0);
      if (!host.read(reinterpret_cast<char*>(mic.data()), count * 2) ||
          !remote.read(reinterpret_cast<char*>(far.data()), count * 2)) throw std::runtime_error("Truncated PCM input");
      if (apm->ProcessReverseStream(far.data(), format, format, scratch.data()) != 0 ||
          apm->set_stream_delay_ms(0) != 0 ||
          apm->ProcessStream(mic.data(), format, format, output.data()) != 0) throw std::runtime_error("AEC3 failed");
      // A muted/silent input frame must never acquire audio from filter history.
      if (std::all_of(mic.begin(), mic.end(), [](int16_t value) { return value == 0; })) output.fill(0);
      if (fwrite(output.data(), 2, count, stdout) != count) throw std::runtime_error("Cannot write PCM output");
      if (done % 160000 == 0 || done + count == frames) {
        fprintf(stderr, "AEC_PROGRESS %llu %llu\n", static_cast<unsigned long long>(done + count), frames);
        fflush(stderr);
      }
    }
    if (fflush(stdout)) throw std::runtime_error("Cannot flush PCM output");
    return 0;
  } catch (const std::exception& error) {
    fprintf(stderr, "AEC error: %s\n", error.what());
    return 1;
  }
}
