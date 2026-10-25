' Go Pray TV channel. Launched by the Go Pray app on any computer on the Wi-Fi:
'   POST http://<roku>:8060/launch/<channelId>?prayer=<p>&voice=<sunni|shia>.<stem>[&test=1]
' Shows the prayer still, plays the Athan once, exits to Home 30 s after it ends.
' Never crashes on bad input. No valid prayer: the welcome screen.
'
' One Athan per prayer per day, whoever sends the launch (several computers may send the same one):
' the TV keeps "<date>/<prayer>" in the registry. A repeat launch of that key never plays the Athan twice:
'   - while it is playing / in its 30 s tail: the same Athan carries on (see the note below)
'   - when the channel was not running (already finished): exit to Home at once
' test=1 always plays and is never recorded. A different prayer always plays.
'
' NOTE (measured on Roku OS 15.3.4): ECP /launch of a channel that is already open does NOT deliver roInput;
' Roku closes the running channel and starts Main again. So a repeat launch cannot "keep going untouched".
' Instead the registry also holds when the audio started and a heartbeat, and the new instance resumes the
' same Athan at the elapsed position (a short audio gap, but one Athan, not two).

sub Main(args as Object)
    print "GOPRAY Main start"
    reg = CreateObject("roRegistrySection", "gopray")
    d = Decide(reg, ParamsOf(args))
    if d.action = "exit" then return

    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.setMessagePort(port)
    input = CreateObject("roInput")
    input.setMessagePort(port)

    scene = screen.CreateScene("AthanScene")
    screen.show()
    scene.observeField("done", port)
    scene.observeField("phase", port)
    scene.params = d.params
    st = { resumed: (d.params.resume = true), started: false, rec: (d.params.test <> true) }

    while true
        msg = wait(5000, port)
        t = type(msg)
        if msg = invalid then
            if st.rec then Beat(reg)
        else if t = "roSGScreenEvent" and msg.isScreenClosed() then
            exit while
        else if t = "roSGNodeEvent" and msg.getField() = "done" then
            exit while
        else if t = "roSGNodeEvent" and msg.getField() = "phase" then
            if st.rec then Record(reg, scene.phase, st)
        else if t = "roInputEvent" then
            ' (not delivered by /launch, see the note above; kept for /input)
            if msg.isInput() then
                d = Decide(reg, ParamsOf(msg.getInfo()))
                if d.action <> "exit" then
                    st = { resumed: (d.params.resume = true), started: false, rec: (d.params.test <> true) }
                    scene.params = d.params
                end if
            end if
        end if
    end while
    if st.rec and reg.Exists("phase") then
        reg.Write("phase", "ended")
        reg.Flush()
    end if
    screen.close()
end sub

' Only the params we know; anything else is dropped.
function ParamsOf(a as Dynamic) as Object
    p = ""
    v = ""
    tst = false
    if type(a) = "roAssociativeArray" then
        if type(a.prayer) = "roString" or type(a.prayer) = "String" then p = LCase(a.prayer)
        if type(a.voice) = "roString" or type(a.voice) = "String" then v = a.voice
        if type(a.test) = "roString" or type(a.test) = "String" then tst = (a.test = "1")
    end if
    return { prayer: p, voice: v, test: tst }
end function

function Now() as Integer
    dt = CreateObject("roDateTime")
    return dt.AsSeconds()
end function

function Pad2(n as Integer) as String
    s = n.ToStr()
    if Len(s) < 2 then s = "0" + s
    return s
end function

function DayKey(prayer as String) as String
    dt = CreateObject("roDateTime")
    dt.ToLocalTime()
    return dt.GetYear().ToStr() + "-" + Pad2(dt.GetMonth()) + "-" + Pad2(dt.GetDayOfMonth()) + "/" + prayer
end function

function RegNum(reg as Object, k as String) as Integer
    ' Integer on purpose: a Float is single precision and cannot hold an epoch second
    if not reg.Exists(k) then return 0
    return Val(reg.Read(k), 10)
end function

sub Beat(reg as Object)
    if reg.Exists("phase") and reg.Read("phase") <> "ended" then
        reg.Write("alive", Now().ToStr())
        reg.Flush()
    end if
end sub

' Decides what a launch does. Returns { action: "play" | "welcome" | "exit", params }.
function Decide(reg as Object, p as Object) as Object
    prayer = p.prayer
    if prayer <> "fajr" and prayer <> "dhuhr" and prayer <> "asr" and prayer <> "maghrib" and prayer <> "isha" then
        print "GOPRAY welcome (no valid prayer)"
        return { action: "welcome", params: p }
    end if
    if p.test then
        print "GOPRAY test play "; prayer
        return { action: "play", params: p }
    end if

    key = DayKey(prayer)
    t = Now()
    if reg.Exists("last") and reg.Read("last") = key then
        phase = reg.Read("phase")
        alive = RegNum(reg, "alive")
        if (phase = "playing" or phase = "tail") and (t - alive) <= 12 then
            ' the same Athan is on right now: carry on with it, do not start a second one
            q = { prayer: prayer, voice: reg.Read("voice"), test: false, resume: true, elapsed: t - RegNum(reg, "start"), tailLeft: 0 }
            if phase = "tail" then
                q.tailLeft = Int(RegNum(reg, "tailEnd") - t)
                if q.tailLeft < 1 then q.tailLeft = 1
            end if
            print "GOPRAY dup ignored "; key; " phase="; phase; " elapsed="; q.elapsed
            reg.Write("alive", t.ToStr())
            reg.Flush()
            return { action: "play", params: q }
        end if
        print "GOPRAY dup exit "; key
        return { action: "exit", params: p }
    end if

    reg.Write("last", key)
    reg.Write("voice", p.voice)
    reg.Write("phase", "playing")
    reg.Write("alive", t.ToStr())
    reg.Write("start", t.ToStr())
    reg.Flush()
    print "GOPRAY play "; key
    return { action: "play", params: p }
end function

sub Record(reg as Object, phase as String, st as Object)
    t = Now()
    if phase = "playing" then
        if not st.resumed and not st.started then reg.Write("start", t.ToStr())
        st.started = true
        reg.Write("phase", "playing")
    else if phase = "tail" then
        if reg.Read("phase") <> "tail" then reg.Write("tailEnd", (t + 30).ToStr())
        reg.Write("phase", "tail")
    end if
    reg.Write("alive", t.ToStr())
    reg.Flush()
end sub
