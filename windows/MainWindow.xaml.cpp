#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"

#include <stdexcept>

namespace winrt::RivetHost::implementation {
namespace {

std::filesystem::path executable_path() {
  std::wstring buffer(32768, L'\0');
  auto const length = ::GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    throw std::runtime_error("GetModuleFileNameW failed");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string utf8(std::filesystem::path const& path) {
  auto const wide = path.wstring();
  if (wide.empty()) return {};
  auto const size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          wide.data(),
                                          static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) throw std::runtime_error("WideCharToMultiByte failed");
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
                            static_cast<int>(wide.size()), result.data(), size,
                            nullptr, nullptr) != size) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  return result;
}

rivet::windows::RacketRuntimeConfig runtime_config() {
  auto const exe = executable_path();
  auto const root = exe.parent_path();
  auto const runtime = root / L"runtime";
  rivet::windows::RacketRuntimeConfig config;
  config.executable_path = utf8(exe);
  config.petite_boot = utf8(runtime / L"petite.boot");
  config.scheme_boot = utf8(runtime / L"scheme.boot");
  config.racket_boot = utf8(runtime / L"racket.boot");
  config.backend_bundle = utf8(root / L"res" / L"core.zo");
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;
  config.dll_dir = runtime.wstring();
  return config;
}

}  // namespace

MainWindow::MainWindow() {
  InitializeComponent();
  Title(L"FlashPilot");
  InitializeBackendAsync();
}

winrt::fire_and_forget MainWindow::InitializeBackendAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = std::make_shared<rivet::windows::Backend>(runtime_config());
  try {
    co_await winrt::resume_background();
    backend->start();
    dispatcher.TryEnqueue([weak, backend = std::move(backend)]() mutable {
      if (auto window = weak.get()) {
        window->backend_ = std::move(backend);
        try {
          // Stream the audited flash workflow into the timeline as the
          // backend emits it.
          auto timeline_dispatcher = window->DispatcherQueue();
          auto timeline_weak = window->get_weak();
          window->backend_->set_event_handler(
              [timeline_dispatcher, timeline_weak](std::string const& name,
                                                   rivet::Value const& value) {
                try {
                  auto event = rivet_app::decode_event(name, value);
                  if (std::holds_alternative<rivet_app::Plan_progressEvent>(event)) {
                    auto const& progress =
                        std::get<rivet_app::Plan_progressEvent>(event);
                    timeline_dispatcher.TryEnqueue(
                        [timeline_weak, line = progress.value] {
                          if (auto current = timeline_weak.get()) {
                            auto text = current->FlashTimeline().Text() +
                                        winrt::to_hstring(line) + L"\n";
                            current->FlashTimeline().Text(text);
                          }
                        });
                  }
                } catch (...) {
                }
              });
          rivet_app::API api(*window->backend_);
          auto const callback_dispatcher = window->DispatcherQueue();
          auto const callback_weak = window->get_weak();
          (void)api.bench_status_async(
              [callback_dispatcher, callback_weak](
                  rivet_app::Result<std::string> result) {
                try {
                  auto value = result.get();
                  callback_dispatcher.TryEnqueue(
                      [callback_weak, value = std::move(value)] {
                        if (auto current = callback_weak.get()) {
                          current->BenchStatusText().Text(
                              winrt::to_hstring(value));
                          current->SetReadyUi();
                        }
                      });
                } catch (std::exception const& e) {
                  auto message = std::string(e.what());
                  callback_dispatcher.TryEnqueue(
                      [callback_weak, message = std::move(message)] {
                        if (auto current = callback_weak.get()) {
                          current->SetErrorUi(message);
                        }
                      });
                }
              });
        } catch (std::exception const& e) {
          window->SetErrorUi(e.what());
        }
      } else {
        std::thread([backend = std::move(backend)]() mutable {
          backend->stop();
        }).detach();
      }
    });
  } catch (std::exception const& e) {
    auto message = std::string(e.what());
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) window->SetErrorUi(message);
    });
  }
}

void MainWindow::RefreshStatus_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RefreshStatusAsync();
}

void MainWindow::Validate_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  ValidateAsync();
}

void MainWindow::VerifyPlan_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  VerifyPlanAsync();
}

void MainWindow::FlashPlan_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  FlashPlanAsync();
}

void MainWindow::ReadDtc_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  ReadDtcAsync();
}

void MainWindow::RefreshStatusAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  if (backend_ == nullptr || !backend_->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  RefreshStatusButton().IsEnabled(false);
  try {
    rivet_app::API api(*backend_);
    (void)api.bench_status_async(
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          try {
            auto value = result.get();
            dispatcher.TryEnqueue([weak, value = std::move(value)] {
              if (auto window = weak.get()) {
                window->BenchStatusText().Text(winrt::to_hstring(value));
                window->RefreshStatusButton().IsEnabled(true);
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->SetErrorUi(message);
                window->RefreshStatusButton().IsEnabled(true);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
    RefreshStatusButton().IsEnabled(true);
  }
}

void MainWindow::ValidateAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  if (backend_ == nullptr || !backend_->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  ValidateButton().IsEnabled(false);
  try {
    rivet_app::API api(*backend_);
    (void)api.bench_validate_async(
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          try {
            auto value = result.get();
            dispatcher.TryEnqueue([weak, value = std::move(value)] {
              if (auto window = weak.get()) {
                window->ValidateText().Text(winrt::to_hstring(value));
                window->ValidateButton().IsEnabled(true);
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->ValidateText().Text(
                    winrt::to_hstring("Error: " + message));
                window->ValidateButton().IsEnabled(true);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    ValidateText().Text(winrt::to_hstring("Error: " + std::string(e.what())));
    ValidateButton().IsEnabled(true);
  }
}

void MainWindow::VerifyPlanAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  if (backend_ == nullptr || !backend_->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  auto path = winrt::to_string(PlanPathBox().Text());
  VerifyPlanButton().IsEnabled(false);
  try {
    rivet_app::API api(*backend_);
    (void)api.verify_plan_async(
        std::move(path),
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          try {
            auto value = result.get();
            dispatcher.TryEnqueue([weak, value = std::move(value)] {
              if (auto window = weak.get()) {
                window->PlanText().Text(winrt::to_hstring(value));
                window->VerifyPlanButton().IsEnabled(true);
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->PlanText().Text(
                    winrt::to_hstring("Error: " + message));
                window->VerifyPlanButton().IsEnabled(true);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    PlanText().Text(winrt::to_hstring("Error: " + std::string(e.what())));
    VerifyPlanButton().IsEnabled(true);
  }
}

void MainWindow::FlashPlanAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  if (backend_ == nullptr || !backend_->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  auto path = winrt::to_string(PlanPathBox().Text());
  FlashTimeline().Text(L"");
  FlashPlanButton().IsEnabled(false);
  try {
    rivet_app::API api(*backend_);
    (void)api.flash_plan_async(
        std::move(path),
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          try {
            auto value = result.get();
            dispatcher.TryEnqueue([weak, value = std::move(value)] {
              if (auto window = weak.get()) {
                window->FlashText().Text(winrt::to_hstring(value));
                window->FlashPlanButton().IsEnabled(true);
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->FlashText().Text(
                    winrt::to_hstring("Error: " + message));
                window->FlashPlanButton().IsEnabled(true);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    FlashText().Text(winrt::to_hstring("Error: " + std::string(e.what())));
    FlashPlanButton().IsEnabled(true);
  }
}

void MainWindow::ReadDtcAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  if (backend_ == nullptr || !backend_->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  ReadDtcButton().IsEnabled(false);
  try {
    rivet_app::API api(*backend_);
    (void)api.dtc_read_async(
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          try {
            auto value = result.get();
            dispatcher.TryEnqueue([weak, value = std::move(value)] {
              if (auto window = weak.get()) {
                window->DtcText().Text(winrt::to_hstring(value));
                window->ReadDtcButton().IsEnabled(true);
              }
            });
          } catch (std::exception const& e) {
            auto message = std::string(e.what());
            dispatcher.TryEnqueue([weak, message = std::move(message)] {
              if (auto window = weak.get()) {
                window->DtcText().Text(
                    winrt::to_hstring("Error: " + message));
                window->ReadDtcButton().IsEnabled(true);
              }
            });
          }
        });
  } catch (std::exception const& e) {
    DtcText().Text(winrt::to_hstring("Error: " + std::string(e.what())));
    ReadDtcButton().IsEnabled(true);
  }
}

void MainWindow::SetReadyUi() {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Success);
  StatusBar().Message(L"Embedded Racket CS is ready");
  RefreshStatusButton().IsEnabled(true);
  ValidateButton().IsEnabled(true);
  VerifyPlanButton().IsEnabled(true);
  FlashPlanButton().IsEnabled(true);
  ReadDtcButton().IsEnabled(true);
}

void MainWindow::SetErrorUi(std::string const& message) {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  StatusBar().Message(winrt::to_hstring(message));
}

}  // namespace winrt::RivetHost::implementation
