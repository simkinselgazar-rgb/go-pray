' Two modes. Launched with a valid prayer: a still, the voice's name, one Athan; 30 s after it ends the channel exits to Home.
' Opened without a prayer (from the store / Home): a welcome screen that stays until Back.
' Back exits at any time (Home is handled by the Roku itself).
' Athan audio: Fajr and the default voice are bundled; every other voice streams from the release below.
' If a stream does not start (no internet, 404, error, nothing playing in 8 s) the bundled default plays instead.

function AudioBase() as String
    return "https://github.com/simkinselgazar-rgb/go-pray/releases/download/tv-audio-v1/" ' AUDIO_BASE
end function

sub init()
    m.aud = m.top.findNode("aud")
    m.timer = m.top.findNode("exitTimer")
    m.aud.observeField("state", "onAudioState")
    m.timer.observeField("fire", "onExitTimer")
    m.startTimer = m.top.findNode("startTimer")
    m.startTimer.observeField("fire", "onStartTimer")
    m.fallbackFile = ""
    m.heard = false
    m.ignoreFinished = false
    m.top.findNode("wName").text = "Go Pray: Athan & Adhan"
    m.top.findNode("wText").text = "Go Pray plays the Athan on this TV at every prayer time. It works with the free Go Pray app on your Mac or Windows PC. Download it, then add this TV in Go Pray " + Chr(8594) + " Settings " + Chr(8594) + " TVs."
    m.top.findNode("wUrl").text = "https://github.com/simkinselgazar-rgb/go-pray"
    m.seeked = false
    m.seekTo = 0.0
    m.top.setFocus(true)
end sub

function KnownVoices() as Object
    return {
        sunni: ["Abdul-Basit", "Abdul-Ghaffar", "Abdul-Hakam", "Adhan-Alaqsa", "Adhan-Egypt", "Adhan-Halab", "Adhan-Madinah", "Adhan-Makkah", "Al-Hussaini", "Bakir-Bash", "Hafez", "Hafiz-Murad", "Minshawi", "Naghshbandi", "Saber", "Sharif-Doman"]
        shia: ["Aghati", "Ghalwash", "Kazem-Zadeh", "Moazzen-Zadeh", "Mohammad-Zadeh", "Rezaeian", "Rowhani-Nejad", "Salimi", "Sharif", "Sobhdel", "Tasvieh-Chi", "Tookhi"]
    }
end function

function Contains(list as Object, s as String) as Boolean
    for each x in list
        if x = s then return true
    end for
    return false
end function

' "sunni.Minshawi" -> { group: "sunni", stem: "Minshawi" }; anything unknown -> the default sunni voice.
function ParseVoice(v as String) as Object
    known = KnownVoices()
    dot = Instr(1, v, ".")
    if dot > 1 then
        group = LCase(Left(v, dot - 1))
        stem = Mid(v, dot + 1)
        if (group = "sunni" or group = "shia") and Contains(known[group], stem) then
            return { group: group, stem: stem }
        end if
    end if
    return { group: "sunni", stem: "Adhan-Makkah" }
end function

function Palette(prayer as String) as Object
    if prayer = "fajr" then return { text: "0xF2E4CCFF" }
    if prayer = "isha" then return { text: "0xEDE9E1FF" }
    if prayer = "dhuhr" then return { text: "0x34444BFF" }
    if prayer = "asr" then return { text: "0x5C4835FF" }
    return { text: "0x4B3719FF" }   ' maghrib
end function

sub onParams()
    p = m.top.params
    prayer = LCase(p.prayer)
    m.timer.control = "stop"
    m.startTimer.control = "stop"
    m.aud.control = "stop"
    m.seeked = false
    m.seekTo = 0.0
    m.fallbackFile = ""
    m.heard = false

    if prayer <> "fajr" and prayer <> "dhuhr" and prayer <> "asr" and prayer <> "maghrib" and prayer <> "isha" then
        print "GOPRAY welcome (no valid prayer)"
        m.top.findNode("bg").uri = "pkg:/images/welcome-bg.jpg"
        m.top.findNode("voice").visible = false
        m.top.findNode("welcome").visible = true
        return
    end if
    m.top.findNode("welcome").visible = false
    m.top.findNode("voice").visible = true
    elapsed = 0.0
    if p.elapsed <> invalid then elapsed = p.elapsed
    tailLeft = 0
    if p.tailLeft <> invalid then tailLeft = p.tailLeft

    bundledDefault = "pkg:/athan-fallback/Adhan-Makkah.mp3"
    if prayer = "fajr" then
        file = "pkg:/athan-fallback/fajr.mp3"
        label = "Athan  " + Chr(183) + "  Sheikh Hamed"
        m.seekTo = 9.0
    else
        v = ParseVoice(p.voice)
        label = "Athan  " + Chr(183) + "  " + v.stem.Replace("-", " ")
        if v.group = "sunni" and v.stem = "Adhan-Makkah" then
            file = bundledDefault
        else
            file = AudioBase() + v.group + "." + v.stem + ".mp3"
            m.fallbackFile = bundledDefault
        end if
    end if

    m.top.findNode("bg").uri = "pkg:/images/still-" + prayer + ".jpg"
    lbl = m.top.findNode("voice")
    lbl.text = label
    pal = Palette(prayer)
    lbl.color = pal.text

    if tailLeft > 0 then
        ' the Athan already ended on this TV: just the still until the 30 s tail runs out
        print "GOPRAY tail only, exit in "; tailLeft
        m.top.phase = "tail"
        m.timer.duration = tailLeft
        m.timer.control = "start"
        return
    end if
    m.seekTo = m.seekTo + elapsed
    print "GOPRAY prayer="; prayer; " file="; file; " seek="; m.seekTo
    startPlay(file)
end sub

sub startPlay(file as String)
    m.timer.control = "stop"
    m.ignoreFinished = true
    c = CreateObject("roSGNode", "ContentNode")
    c.url = file
    c.streamFormat = "mp3"
    if Left(file, 4) = "http" then
        c.HttpCertificatesFile = "common:/certs/ca-bundle.crt"
        m.startTimer.control = "stop"
        m.startTimer.control = "start"
    end if
    m.aud.content = c
    m.aud.control = "play"
end sub

' The stream did not come up: play the bundled default instead (once).
sub fallBack(why as String)
    if m.fallbackFile = "" or m.heard then return
    print "GOPRAY stream failed ("; why; ") -> bundled fallback"
    f = m.fallbackFile
    m.fallbackFile = ""
    m.startTimer.control = "stop"
    m.aud.control = "stop"
    startPlay(f)
end sub

sub onStartTimer()
    if not m.heard then fallBack("no audio in 8 s")
end sub

sub onAudioState()
    s = m.aud.state
    print "GOPRAY audio state="; s
    if s = "playing" then
        m.heard = true
        m.top.phase = "playing"
        m.startTimer.control = "stop"
        if m.seekTo > 0 and not m.seeked then
            m.seeked = true
            m.aud.seek = m.seekTo
            print "GOPRAY seek requested "; m.seekTo
        end if
    else if s = "buffering" then
        m.ignoreFinished = false
    else if s = "finished" then
        if m.ignoreFinished then
            ' the stop of the previous content reports finished; not a real end
        else if m.heard then
            print "GOPRAY finished, exit in 30 s"
            m.top.phase = "tail"
            m.timer.duration = 30
            m.timer.control = "start"
        else if m.fallbackFile <> "" then
            fallBack("finished without playing")
        else
            print "GOPRAY finished without playing, exit in 10 s"
            m.top.phase = "tail"
            m.timer.duration = 10
            m.timer.control = "start"
        end if
    else if s = "error" then
        if m.fallbackFile <> "" and not m.heard then
            fallBack("error")
        else
            print "GOPRAY audio error, exit in 10 s"
            m.top.phase = "tail"
            m.timer.duration = 10
            m.timer.control = "start"
        end if
    end if
end sub

sub onExitTimer()
    print "GOPRAY exit timer fired"
    m.top.done = true
end sub

function onKeyEvent(key as String, press as Boolean) as Boolean
    if press and key = "back" then
        m.top.done = true
        return true
    end if
    return false
end function
