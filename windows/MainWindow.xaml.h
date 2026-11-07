#pragma once

#include "pch.h"
#include "MainWindow.g.h"

namespace winrt::RivetHost::implementation {

struct MainWindow : MainWindowT<MainWindow> {
  MainWindow();

  void RefreshStatus_Click(winrt::Windows::Foundation::IInspectable const&,
                           Microsoft::UI::Xaml::RoutedEventArgs const&);
  void Validate_Click(winrt::Windows::Foundation::IInspectable const&,
                      Microsoft::UI::Xaml::RoutedEventArgs const&);
  void VerifyPlan_Click(winrt::Windows::Foundation::IInspectable const&,
                        Microsoft::UI::Xaml::RoutedEventArgs const&);
  void FlashPlan_Click(winrt::Windows::Foundation::IInspectable const&,
                       Microsoft::UI::Xaml::RoutedEventArgs const&);
  void ReadDtc_Click(winrt::Windows::Foundation::IInspectable const&,
                     Microsoft::UI::Xaml::RoutedEventArgs const&);

 private:
  winrt::fire_and_forget InitializeBackendAsync();
  void RefreshStatusAsync();
  void ValidateAsync();
  void VerifyPlanAsync();
  void FlashPlanAsync();
  void ReadDtcAsync();
  void SetReadyUi();
  void SetErrorUi(std::string const& message);

  std::shared_ptr<rivet::windows::Backend> backend_;
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
