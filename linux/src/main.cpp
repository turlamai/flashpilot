#include <gtk/gtk.h>

#include <atomic>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "GeneratedBackend.hpp"

namespace {

struct AppState {
  GtkWindow* window{nullptr};
  GtkLabel* status{nullptr};
  GtkLabel* bench{nullptr};
  GtkLabel* validate{nullptr};
  GtkLabel* plan{nullptr};
  GtkLabel* flash{nullptr};
  GtkLabel* dtc{nullptr};
  GtkEntry* plan_path{nullptr};
  GtkButton* refresh_button{nullptr};
  GtkButton* validate_button{nullptr};
  GtkButton* verify_button{nullptr};
  GtkButton* flash_button{nullptr};
  GtkButton* dtc_button{nullptr};

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};
};

AppState g_state;

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

struct RuntimeLayout {
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
};

std::optional<RuntimeLayout> discover_runtime_layout() {
  auto const root = executable_path().parent_path();
  RuntimeLayout layout{root / "runtime" / "petite.boot",
                       root / "runtime" / "scheme.boot",
                       root / "runtime" / "racket.boot",
                       root / "res" / "core.zo"};
  if (std::filesystem::exists(layout.petite_boot) &&
      std::filesystem::exists(layout.scheme_boot) &&
      std::filesystem::exists(layout.racket_boot) &&
      std::filesystem::exists(layout.core)) {
    return layout;
  }
  return std::nullopt;
}

void set_status(std::string const& value) {
  gtk_label_set_text(g_state.status, value.c_str());
}

void set_controls_sensitive(bool sensitive) {
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.refresh_button), sensitive);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.validate_button), sensitive);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.verify_button), sensitive);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.flash_button), sensitive);
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.dtc_button), sensitive);
}

struct StringResult {
  GtkLabel* target{nullptr};
  GtkButton* button{nullptr};
  bool marks_ready{false};
  bool ok{false};
  std::string value;
};

int on_string_delivered(gpointer user_data) {
  std::unique_ptr<StringResult> result(static_cast<StringResult*>(user_data));
  gtk_label_set_text(result->target, result->value.c_str());
  if (result->button != nullptr) {
    gtk_widget_set_sensitive(GTK_WIDGET(result->button), TRUE);
  }
  if (result->marks_ready && result->ok) {
    set_status("Embedded Racket CS is ready");
    set_controls_sensitive(true);
  } else if (!result->ok) {
    set_status("Backend error: " + result->value);
  }
  return G_SOURCE_REMOVE;
}

void deliver_string(rivet_app::Result<std::string> result, GtkLabel* target,
                    GtkButton* button = nullptr, bool marks_ready = false) {
  auto* delivered = new StringResult;
  delivered->target = target;
  delivered->button = button;
  delivered->marks_ready = marks_ready;
  try {
    delivered->value = result.get();
    delivered->ok = true;
  } catch (std::exception const& error) {
    delivered->value = std::string("Error: ") + error.what();
  } catch (...) {
    delivered->value = "Error: unknown backend failure";
  }
  g_idle_add(on_string_delivered, delivered);
}

int on_backend_finished(gpointer) {
  if (g_state.startup_thread.joinable()) g_state.startup_thread.join();
  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::string error;
  {
    std::lock_guard lock(g_state.startup_mutex);
    backend = std::move(g_state.startup_backend);
    error = std::move(g_state.startup_error);
  }
  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    if (backend != nullptr) backend->stop();
    return G_SOURCE_REMOVE;
  }
  if (!error.empty() || backend == nullptr) {
    set_status("Backend error: " +
               (error.empty() ? "startup completed without a backend" : error));
    return G_SOURCE_REMOVE;
  }
  g_state.backend = std::move(backend);
  g_state.api = std::make_unique<rivet_app::API>(*g_state.backend);
  // Stream the audited flash workflow into the flash section label.
  g_state.backend->set_event_handler([](std::string const& name,
                                        rivet::Value const& value) {
    try {
      auto event = rivet_app::decode_event(name, value);
      if (std::holds_alternative<rivet_app::Plan_progressEvent>(event)) {
        auto const& progress = std::get<rivet_app::Plan_progressEvent>(event);
        g_idle_add_full(
            G_PRIORITY_DEFAULT,
            [](gpointer data) -> gboolean {
              auto* line = static_cast<std::string*>(data);
              if (g_state.flash != nullptr) {
                auto* current = gtk_label_get_text(g_state.flash);
                std::string text = (current != nullptr ? current : "") + *line + "\n";
                gtk_label_set_text(g_state.flash, text.c_str());
              }
              delete line;
              return G_SOURCE_REMOVE;
            },
            new std::string(progress.value), nullptr);
      }
    } catch (...) {
    }
  });
  set_status("Embedded Racket CS is ready");
  set_controls_sensitive(true);
  (void)g_state.api->bench_status_async([](rivet_app::Result<std::string> result) {
    deliver_string(std::move(result), g_state.bench);
  });
  return G_SOURCE_REMOVE;
}

void start_backend() {
  auto layout = discover_runtime_layout();
  if (!layout.has_value()) {
    set_status("Missing Rivet runtime layout next to the executable");
    return;
  }
  rivet::linux_runtime::RacketRuntimeConfig config;
  config.executable_path = executable_path().string();
  config.petite_boot = layout->petite_boot.string();
  config.scheme_boot = layout->scheme_boot.string();
  config.racket_boot = layout->racket_boot.string();
  config.backend_bundle = layout->core.string();
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;

  g_state.startup_thread = std::thread([config = std::move(config)]() mutable {
    auto backend =
        std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
    try {
      backend->start();
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_backend = std::move(backend);
    } catch (std::exception const& error) {
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_error = error.what();
    }
    g_idle_add(on_backend_finished, nullptr);
  });
}

void on_refresh_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) return;
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.refresh_button), FALSE);
  (void)g_state.api->bench_status_async([](rivet_app::Result<std::string> result) {
    deliver_string(std::move(result), g_state.bench, g_state.refresh_button);
  });
}

void on_validate_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) return;
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.validate_button), FALSE);
  (void)g_state.api->bench_validate_async([](rivet_app::Result<std::string> result) {
    deliver_string(std::move(result), g_state.validate, g_state.validate_button);
  });
}

void on_verify_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) return;
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.verify_button), FALSE);
  std::string path = gtk_editable_get_text(GTK_EDITABLE(g_state.plan_path));
  (void)g_state.api->verify_plan_async(
      std::move(path), [](rivet_app::Result<std::string> result) {
        deliver_string(std::move(result), g_state.plan, g_state.verify_button);
      });
}

void on_flash_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) return;
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.flash_button), FALSE);
  gtk_label_set_text(g_state.flash, "");
  std::string path = gtk_editable_get_text(GTK_EDITABLE(g_state.plan_path));
  (void)g_state.api->flash_plan_async(
      std::move(path), [](rivet_app::Result<std::string> result) {
        deliver_string(std::move(result), g_state.flash, g_state.flash_button);
      });
}

void on_dtc_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) return;
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.dtc_button), FALSE);
  (void)g_state.api->dtc_read_async([](rivet_app::Result<std::string> result) {
    deliver_string(std::move(result), g_state.dtc, g_state.dtc_button);
  });
}

GtkWidget* section(char const* heading, GtkLabel** result, char const* button_text,
                   GtkButton** button, GCallback callback) {
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  auto* title = gtk_label_new(heading);
  gtk_label_set_xalign(GTK_LABEL(title), 0.0f);
  gtk_widget_add_css_class(title, "title-3");
  auto* value = gtk_label_new("—");
  gtk_label_set_xalign(GTK_LABEL(value), 0.0f);
  gtk_label_set_wrap(GTK_LABEL(value), TRUE);
  gtk_widget_add_css_class(value, "monospace");
  auto* action = gtk_button_new_with_label(button_text);
  gtk_widget_set_sensitive(action, FALSE);
  gtk_widget_set_hexpand(action, TRUE);
  g_signal_connect(action, "clicked", callback, nullptr);
  gtk_box_append(GTK_BOX(box), title);
  gtk_box_append(GTK_BOX(box), value);
  gtk_box_append(GTK_BOX(box), action);
  *result = GTK_LABEL(value);
  *button = GTK_BUTTON(action);
  return box;
}

void on_activate(GtkApplication* app, gpointer) {
  if (g_state.window != nullptr) {
    gtk_window_present(g_state.window);
    return;
  }
  auto* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window), "FlashPilot");
  gtk_window_set_default_size(GTK_WINDOW(window), 640, 720);

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
  gtk_widget_set_margin_top(root, 24);
  gtk_widget_set_margin_bottom(root, 24);
  gtk_widget_set_margin_start(root, 32);
  gtk_widget_set_margin_end(root, 32);
  auto* title = gtk_label_new("FlashPilot");
  gtk_label_set_xalign(GTK_LABEL(title), 0.0f);
  gtk_widget_add_css_class(title, "title-1");
  auto* subtitle = gtk_label_new("Agent-native ECU flashing cockpit");
  gtk_label_set_xalign(GTK_LABEL(subtitle), 0.0f);
  gtk_widget_add_css_class(subtitle, "dim-label");
  auto* status = gtk_label_new("Starting embedded Racket CS…");
  gtk_label_set_xalign(GTK_LABEL(status), 0.0f);
  gtk_widget_add_css_class(status, "dim-label");
  gtk_box_append(GTK_BOX(root), title);
  gtk_box_append(GTK_BOX(root), subtitle);
  gtk_box_append(GTK_BOX(root), status);

  gtk_box_append(GTK_BOX(root),
                 section("Bench", &g_state.bench, "Refresh status",
                         &g_state.refresh_button,
                         G_CALLBACK(on_refresh_clicked)));
  gtk_box_append(GTK_BOX(root),
                 section("Readiness", &g_state.validate, "Validate bench",
                         &g_state.validate_button,
                         G_CALLBACK(on_validate_clicked)));

  auto* plan_box = section("Plan", &g_state.plan, "Verify plan",
                           &g_state.verify_button,
                           G_CALLBACK(on_verify_clicked));
  auto* path = gtk_entry_new();
  gtk_editable_set_text(GTK_EDITABLE(path), "examples/plan.sim.json");
  gtk_accessible_update_property(GTK_ACCESSIBLE(path),
                                 GTK_ACCESSIBLE_PROPERTY_LABEL, "Plan path", -1);
  gtk_box_insert_child_after(GTK_BOX(plan_box), path,
                             gtk_widget_get_first_child(plan_box));
  g_state.plan_path = GTK_ENTRY(path);
  gtk_box_append(GTK_BOX(root), plan_box);
  auto* flash_box = section("Flash (simulated bench)", &g_state.flash,
                            "Flash plan", &g_state.flash_button,
                            G_CALLBACK(on_flash_clicked));
  gtk_box_append(GTK_BOX(root), flash_box);
  gtk_box_append(GTK_BOX(root),
                 section("Diagnostics", &g_state.dtc, "Read DTCs",
                         &g_state.dtc_button, G_CALLBACK(on_dtc_clicked)));

  auto* scroll = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER,
                                 GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), root);
  gtk_window_set_child(GTK_WINDOW(window), scroll);

  g_state.window = GTK_WINDOW(window);
  g_state.status = GTK_LABEL(status);
  gtk_window_present(GTK_WINDOW(window));
  start_backend();
}

void on_shutdown(GApplication*, gpointer) {
  g_state.shutting_down.store(true, std::memory_order_release);
  if (g_state.startup_thread.joinable()) g_state.startup_thread.join();
  {
    std::lock_guard lock(g_state.startup_mutex);
    if (g_state.startup_backend != nullptr) g_state.startup_backend->stop();
    g_state.startup_backend.reset();
  }
  if (g_state.backend != nullptr) g_state.backend->stop();
}

}  // namespace

int main(int argc, char** argv) {
  auto* app = gtk_application_new("site.jrtx.flashpilot",
                                  G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
