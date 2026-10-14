// Helper process (renderer, GPU, utility…). The renderer side exposes `window.__browser.post(name, body)`
// and runs feature scripts from the browser process at document start (CEF has no isolated worlds API).
#include <map>
#include <string>

#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

class PostHandler : public CefV8Handler {
public:
    bool Execute(const CefString &name, CefRefPtr<CefV8Value> object, const CefV8ValueList &arguments,
                 CefRefPtr<CefV8Value> &retval, CefString &exception) override {
        if (arguments.empty() || !arguments[0]->IsString()) return true;
        CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
        std::string json = "null";
        if (arguments.size() > 1) {
            // JSON.stringify(body) in the page's own context.
            CefRefPtr<CefV8Value> JSON = context->GetGlobal()->GetValue("JSON");
            CefRefPtr<CefV8Value> stringify = JSON ? JSON->GetValue("stringify") : nullptr;
            if (stringify && stringify->IsFunction()) {
                CefRefPtr<CefV8Value> result = stringify->ExecuteFunction(JSON, {arguments[1]});
                if (result && result->IsString()) json = result->GetStringValue().ToString();
            }
        }
        CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create("browser.post");
        message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
        message->GetArgumentList()->SetString(1, json);
        context->GetFrame()->SendProcessMessage(PID_BROWSER, message);
        return true;
    }
    IMPLEMENT_REFCOUNTING(PostHandler);
};

class RendererApp : public CefApp, public CefRenderProcessHandler {
public:
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

    void OnBrowserCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDictionaryValue> extra_info) override {
        if (extra_info && extra_info->HasKey("scripts")) scripts_[browser->GetIdentifier()] = extra_info->GetList("scripts")->Copy();
    }

    void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override { scripts_.erase(browser->GetIdentifier()); }

    void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) override {
        CefRefPtr<CefV8Value> bridge = CefV8Value::CreateObject(nullptr, nullptr);
        bridge->SetValue("post", CefV8Value::CreateFunction("post", new PostHandler), V8_PROPERTY_ATTRIBUTE_READONLY);
        context->GetGlobal()->SetValue("__browser", bridge,
            static_cast<cef_v8_propertyattribute_t>(V8_PROPERTY_ATTRIBUTE_READONLY | V8_PROPERTY_ATTRIBUTE_DONTENUM | V8_PROPERTY_ATTRIBUTE_DONTDELETE));

        auto it = scripts_.find(browser->GetIdentifier());
        if (it == scripts_.end()) return;
        CefRefPtr<CefListValue> list = it->second;
        for (size_t i = 0; i < list->GetSize(); i++) {
            CefRefPtr<CefDictionaryValue> s = list->GetDictionary(i);
            if (s->GetBool("mainFrameOnly") && !frame->IsMain()) continue;
            std::string source = s->GetString("source").ToString();
            if (!s->GetBool("documentStart")) {
                source = "(() => { const run = () => {" + source +
                         "}; if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true }); else run(); })();";
            }
            CefRefPtr<CefV8Value> retval;
            CefRefPtr<CefV8Exception> exception;
            context->Eval(source, "", 0, retval, exception);
        }
    }

private:
    std::map<int, CefRefPtr<CefListValue>> scripts_;
    IMPLEMENT_REFCOUNTING(RendererApp);
};

int main(int argc, char *argv[]) {
    CefScopedLibraryLoader loader;
    if (!loader.LoadInHelper()) return 1;
    CefMainArgs args(argc, argv);
    CefRefPtr<RendererApp> app(new RendererApp);
    return CefExecuteProcess(args, app.get(), nullptr);
}
