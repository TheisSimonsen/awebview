module awebview.gui.application;


import core.thread;

import std.exception;
import std.file;
import std.concurrency;
import std.datetime;

import awebview.wrapper.webcore;
import awebview.gui.resourceinterceptor;
import awebview.sound;
import awebview.clock;
import awebview.gui.activity;
import awebview.gui.html;
import derelict.sdl2.sdl;
import derelict.sdl2.mixer;
import msgpack;
import carbon.utils;
import carbon.channel;



struct ImmediateMessage 
{
    string fromId;
    string toId;
    string type;
    immutable(ubyte)[] data;
}


abstract class Application
{
    this(string savedFileName)
    {
        _savedFileName = savedFileName;
        if(exists(savedFileName))
            _savedData = unpack!(ubyte[][string])(cast(ubyte[])std.file.read(savedFileName));

        _ch = channel!(ImmediateMessage);
        _ownerTid = thisTid;
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


    static
    void sendMessage(string fromId, string toId, string type, immutable(ubyte)[] data)
    {
        shared msg = ImmediateMessage(fromId, toId, type, data);
        _ch.put(msg);
        _ownerTid.send(EventNotification.init);
    }


    void onReceiveImmediateMessage(ImmediateMessage msg);


  private:
    ubyte[][string] _savedData;
    string _savedFileName;


    static shared typeof(channel!(ImmediateMessage)) _ch;
    __gshared Tid _ownerTid;

    static struct EventNotification {}
}


class SDLApplication : Application
{
    static immutable savedDataFileName = "saved.mpac";

    private
    this()
    {
        super(savedDataFileName);
        _soundManager = SoundManager.instance;
        _timer = new Timer();
    }


    static
    SDLApplication instance() @property
    {
        if(_instance is null){
            DerelictSDL2.load();
            DerelictSDL2Mixer.load();

            enforce(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) >= 0);

            {
                int flags = MIX_INIT_FLAC | MIX_INIT_MP3 | MIX_INIT_OGG;
                int ini = Mix_Init(flags);
                enforce((ini&flags) == flags, "Failed to init required .ogg and .mod\nMix_Init: " ~ to!string(Mix_GetError()));
                enforce(Mix_OpenAudio(44100, AUDIO_S16SYS, 2, 4096) >= 0);
            }

            _instance = new SDLApplication();

            auto config = WebConfig();
            config.additionalOptions ~= "--use-gl=desktop";
            WebCore.initialize(config);
            WebCore.instance.resourceInterceptor = new LocalResourceInterceptor(_instance, getcwd());
        }

        return _instance;
    }


    final
    shared(SoundManager) soundManager() pure nothrow @safe @nogc
    {
        return _soundManager;
    }


    final
    Timer timer() pure nothrow @safe @nogc
    {
        return _timer;
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
        Mix_CloseAudio();
        Mix_Quit();
        SDL_Quit();
    }


    auto newFactoryOf(A)(WebPreferences pref)
    if(is(A : Activity))
    {
        auto session = WebCore.instance.createWebSession(WebString(""), pref);
        auto factory = A.factory();
        factory.webSession = session;
        return factory;
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
        alias A = typeof(return);

        A act;
        with(this.newFactoryOf!A(pref)){
            index = 0;
            act = newInstance;
            this.addActivity(act);
        }
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
            _timer.onUpdate();

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

            //Thread.sleep(dur!"msecs"(5));
            auto nowTime = Clock.currTime;
            auto target = nowTime + dur!"msecs"(5);
            while(target > nowTime
                && receiveTimeout(target - nowTime,
                    (Application.EventNotification){
                        if(auto p = Application._ch.pop!(ImmediateMessage)){
                            auto msg = *p;
                            onReceiveImmediateMessage(msg);
                        }
                    }
                )
            )
            {
                nowTime = Clock.currTime;
            }

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



    override
    void onReceiveImmediateMessage(ImmediateMessage msg)
    {
        foreach(k, e; _acts.maybeModified) e.onReceiveImmediateMessage(msg);
        foreach(k, e; _detachedActs.maybeModified) e.onReceiveImmediateMessage(msg);
        //_soundManager.onReceiveImmediateMessage(msg);
    }


  private:
    SDLActivity[string] _acts;
    SDLActivity[string] _detachedActs;
    SDLPopupActivity _popupRoot;
    bool _isRunning;
    bool _isShouldQuit;
    ubyte[][string] _savedData;

    void delegate()[] _runNextFrame;

    shared(SoundManager) _soundManager;

    Timer _timer;

    static SDLApplication _instance;
}
