module awebview.gui.application;

import std.exception;
import std.file;

import awebview.wrapper.webcore;
import awebview.gui.resourceinterceptor;

import awebview.gui.activity;
import awebview.gui.html;
import derelict.sdl2.sdl;
import msgpack;
import carbon.utils;

import core.thread;


abstract class Application
{
    this(string savedFileName)
    {
        _savedFileName = savedFileName;
        if(exists(savedFileName))
            _savedData = unpack!(ubyte[][string])(cast(ubyte[])std.file.read(savedFileName));
    }


    void onDestroy()
    {
        if(_savedData.length)
            std.file.write(_savedFileName, pack(_savedData));
    }


    final
    @property
    ref ubyte[][string] savedData() pure nothrow @safe @nogc { return _savedData; }

    void addActivity(Activity activity);

    final
    void opOpAssign(string op : "~")(Activity activity)
    {
        addActivity(activity);
    }


    bool hasActivity(string id);
    Activity getActivity(string id);

    final
    Activity opIndex(string id) { return getActivity(id); }

    int opApplyActivities(scope int delegate(Activity activity));

    void attachActivity(string id);
    void detachActivity(string id);
    void destroyActivity(string id);

    void runAtNextFrame(void delegate());

    void run();
    bool isRunning() @property;

    void shutdown();



    final
    @property
    string exeDir() const
    {
        import std.path : dirName;
        import std.file : thisExePath;

        return dirName(thisExePath);
    }


  private:
    ubyte[][string] _savedData;
    string _savedFileName;
}


class SDLApplication : Application
{
    static immutable savedDataFileName = "saved.mpac";

    private
    this()
    {
        super(savedDataFileName);
    }


    static
    SDLApplication instance() @property
    {
        if(_instance is null){
            DerelictSDL2.load();
            enforce(SDL_Init(SDL_INIT_VIDEO) >= 0);

            _instance = new SDLApplication();

            auto config = WebConfig();
            config.additionalOptions ~= "--use-gl=desktop";
            WebCore.initialize(config);
            WebCore.instance.resourceInterceptor = new LocalResourceInterceptor(_instance, getcwd());
        }

        return _instance;
    }


    override
    void onDestroy()
    {
        while(_acts.length){
            foreach(id, activity; _acts.maybeModified){
                activity.onDetach();
                activity.onDestroy();
                if(_acts[id] is activity)
                    _acts.remove(id);
            }
        }

        while(_detachedActs.length){
            foreach(id, activity; _detachedActs.maybeModified){
                activity.onDestroy();
                if(_detachedActs[id] is activity)
                    _detachedActs.remove(id);
            }
        }

        super.onDestroy();
    }


    A createActivity(A : SDLActivity)(WebPreferences pref, A delegate(WebSession) dg)
    {
        auto session = WebCore.instance.createWebSession(WebString(""), pref);

        auto act = dg(session);
        addActivity(act);

        return act;
    }


    SDLActivity createActivity(WebPreferences pref, HTMLPage page, string actID, uint width, uint height, string title)
    {
        return this.createActivity(pref, delegate(WebSession session){
            auto act = new SDLActivity(actID, width, height, title, session);
            act ~= page;
            act.load(page);
            return act;
        });
    }


    override
    void addActivity(Activity act)
    in {
      assert(typeid(act) == typeid(SDLActivity));
    }
    body {
        addActivity(cast(SDLActivity)act);
    }


    void addActivity(SDLActivity act)
    in {
        assert(act !is null);
    }
    body {
        _acts[act.id] = act;

        if(_isRunning){
            act.onStart(this);
            act.onAttach();
        }
    }


    SDLPopupActivity initPopup(WebPreferences pref)
    {
        auto act = this.createActivity(pref, delegate(WebSession session){
            return new SDLPopupActivity(0, session);
        });
        this.detachActivity(act.id);
        _popupRoot = act;
        return act;
    }


    final
    @property
    auto activities(this This)() pure nothrow @safe @nogc
    {
        static struct Result{
            auto opIndex(string id) { return _app.getActivity(id); }
            auto opIndex(uint windowID) { return _app.getActivity(windowID); }
            auto opIndex(SDL_Window* sdlWindow) { return _app.getActivity(sdlWindow); }

            auto opBinaryRight(string op : "in")(string id)
            {
                if(auto p = id in _app._acts)
                    return p;
                else if(auto p = id in _app._detachedActs)
                    return p;
                else
                    return null;
            }

          private:
            This _app;
        }

        return Result(this);
    }


    final override
    bool hasActivity(string id)
    {
        if(auto p = id in _acts)
            return true;
        else if(auto p = id in _detachedActs)
            return true;
        else
            return false;
    }


    final
    SDLActivity getActivity(uint windowID)
    {
        foreach(k, a; _acts)
            if(a.windowID == windowID)
                return a;

        foreach(k, a; _detachedActs)
            if(a.windowID == windowID)
                return a;

        return null;
    }


    final override
    SDLActivity getActivity(string id)
    {
        return _acts.get(id, _detachedActs.get(id, null));
    }


    final
    SDLActivity getActivity(SDL_Window* sdlWind)
    {
        foreach(k, a; _acts)
            if(a.sdlWindow == sdlWind)
                return a;

        foreach(k, a; _detachedActs)
            if(a.sdlWindow == sdlWind)
                return a;

        return null;
    }


    final override
    int opApplyActivities(scope int delegate(Activity activity) dg)
    {
        foreach(k, ref e; _acts)
            if(auto res = dg(e))
                return res;

        foreach(k, ref e; _detachedActs)
            if(auto res = dg(e))
                return res;

        return 0;
    }


    final
    @property
    SDLPopupActivity popupActivity()
    {
        return _popupRoot;
    }


    override
    void attachActivity(string id)
    {
        if(id in _acts)
            return;

        auto act = _detachedActs[id];
        if(_isRunning) act.onAttach();
        _detachedActs.remove(id);
        _acts[id] = act;
    }


    override
    void detachActivity(string id)
    {
        if(id in _detachedActs)
            return;

        auto act = _acts[id];
        if(_isRunning) act.onDetach();
        _acts.remove(id);
        _detachedActs[id] = act;
    }


    override
    void destroyActivity(string id)
    {
        if(auto p = id in _acts){
            auto act = *p;
            act.onDetach();
            act.onDestroy();
            _acts.remove(id);
        }else if(auto p = id in _detachedActs){
            auto act = *p;
            act.onDestroy();
            _detachedActs.remove(id);
        }else
            enforce(0);
    }


    override
    void runAtNextFrame(void delegate() dg)
    {
        _runNextFrame ~= dg;
    }


    override
    void run()
    {
        _isRunning = true;

        auto wc = WebCore.instance;
        wc.update();

        foreach(k, a; _acts.maybeModified){
            a.onStart(this);
            a.onAttach();
        }

        foreach(k, a; _detachedActs.maybeModified){
            a.onStart(this);
        }

      LInf:
        while(!_isShouldQuit)
        {
            foreach(e; _runNextFrame)
                e();

            _runNextFrame.length = 0;

            {
                SDL_Event event;
                while(SDL_PollEvent(&event)){
                    onSDLEvent(&event);
                    if(_isShouldQuit)
                        break LInf;
                }
            }

            foreach(k, a; _acts.maybeModified){
                a.onUpdate();

                if(a.isShouldClosed)
                    destroyActivity(a.id);

                if(_isShouldQuit)
                    break LInf;
            }

            if(_acts.length == 0)
                shutdown();

            foreach(k, a; _detachedActs.maybeModified){
                if(a.isShouldClosed)
                    destroyActivity(a.id);

                if(_isShouldQuit)
                    break LInf;
            }

            Thread.sleep(dur!"msecs"(5));
            wc.update();
        }
        _isRunning = false;

        shutdown();
    }


    override
    @property
    bool isRunning() { return _isRunning; }


    override
    void shutdown()
    {
        if(!_isShouldQuit && _isRunning)
            _isShouldQuit = true;
        else{
            _isRunning = false;
            _isShouldQuit = true;

            this.onDestroy();

            SDL_Quit();
            WebCore.shutdown();
        }
    }


    void onSDLEvent(const SDL_Event* event)
    {
        foreach(k, a; _acts.maybeModified)
            a.onSDLEvent(event);

        switch(event.type)
        {
          case SDL_QUIT:
            shutdown();
            break;

          default:
            break;
        }
    }


  private:
    SDLActivity[string] _acts;
    SDLActivity[string] _detachedActs;
    SDLPopupActivity _popupRoot;
    bool _isRunning;
    bool _isShouldQuit;
    ubyte[][string] _savedData;

    void delegate()[] _runNextFrame;

    static SDLApplication _instance;
}
