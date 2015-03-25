import awebview.gui.application;
import awebview.gui.activity;
import awebview.gui.html;
import awebview.gui.widgets.button;
import awebview.wrapper;

import carbon.utils;


void main()
{
    auto app = SDLApplication.instance;
    auto pref = WebPreferences.recommended;

    app.createActivity(pref, delegate(WebSession session){
      auto activity = new SDLActivity("MainActivity", 600, 400, "Hello!", session);
      auto topPage = new TopPage();

      activity ~= topPage;
      activity.load("topPage");

      return activity;
    });

    app.run();
}


final class TopPage : TemplateHTMLPage!(import("top.html"))
{
    this()
    {
        super("topPage", null);

        this ~= (){
            auto btn = new InputButton!()("open_new");
            btn.staticSet("value", "Open new window");
            btn.onClick.connect!"onClickOpenWindow"(this);
            return btn;
        }();

        this ~= (){
            auto btn = new InputButton!()("close_all");
            btn.staticSet("value", "Close all windows");
            btn.onClick.connect!"onClickCloseAll"(this);
            return btn;
        }();

        this ~= (){
            auto btn = new InputButton!()("show_all");
            btn.staticSet("value", "Show all windows");
            btn.onClick.connect!"onClickShowAll"(this);
            return btn;
        }();

        this ~= (){
            auto btn = new InputButton!()("hide_all");
            btn.staticSet("value", "Hide all windows");
            btn.onClick.connect!"onClickHideAll"(this);
            return btn;
        }();
    }


    void onClickOpenWindow(FiredContext ctx, WeakRef!(const(JSArrayCpp)) args)
    {
        application.to!SDLApplication.createActivity(WebPreferences.recommended,
        delegate(WebSession session){
            ++_n;
            string strN = _n.to!string;

            auto activity = new SDLActivity("MainActivity" ~ strN, 600, 400, strN ~ "!", session);
            auto helloPage = new ChildPage();

            activity ~= helloPage;
            activity.load("hello");

            _children[activity.id] = activity;

            return activity;
        });
    }


    void onClickCloseAll(FiredContext ctx, WeakRef!(const(JSArrayCpp)) args)
    {
        foreach(k, e; _children.maybeModified){
            e.close();
        }
    }


    void onClickShowAll(FiredContext ctx, WeakRef!(const(JSArrayCpp)) args)
    {
        foreach(k; _children.byKey)
            application.attachActivity(k);
    }


    void onClickHideAll(FiredContext ctx, WeakRef!(const(JSArrayCpp)) args)
    {
        foreach(k; _children.byKey)
            application.detachActivity(k);
    }


    final class ChildPage : TemplateHTMLPage!(import("child.html"))
    {
        this()
        {
            super("hello", null);

            this ~= (){
                auto btn = new InputButton!()("close_this");
                btn.staticSet("value", "Close this window");
                btn.onClick.connect!"onClickCloseThis"(this);
                return btn;
            }();
        }


        void onClickCloseThis(FiredContext ctx, WeakRef!(const(JSArrayCpp)) args)
        {
            activity.close();
        }


        override
        void onDestroy()
        {
            super.onDestroy();
            _children.remove(this.activity.id);
        }
    }


  private:
    size_t _n;
    SDLActivity[string] _children;
}
