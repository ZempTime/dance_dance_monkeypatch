# Dance Dance Monkeypatch: a rhythm game that rewrites itself while you play.
#
# Hit the notes as they reach the rings with the arrow keys (or D F J K), and the bacon with
# Space. Every section of every song evals a monkeypatch on the playfield: the highway wobbles,
# goes round, falls upwards, spirals, turns 3D and shuffles its own lanes, while two foxes in
# little red shoes tell you how it's going. Don't step on the nils.
#
# The songs are written below in a tiny tracker notation. A chiptune synth in plain Ruby
# renders each one to a WAV the first time it is played (cached after that) and afplay plays
# it; the foxes talk through `say`. M mutes the music, V the foxes, C calibrates the timing,
# [ and ] nudge it while you play.

require "digest"
require "fileutils"
require "json"
require "tmpdir"

W, H = 960, 640
INK = "#fff4e0"
MUTED = "#b4a3d6"
CREAM = "#fff1dc"
DARK = "#24112f"
SHOE_RED = "#ff3b6b"
LANE_RGB = [[255, 59, 107], [45, 226, 230], [255, 210, 63], [138, 255, 92]].freeze
NIL_RGB = [150, 138, 172].freeze
DISPLAY = "Impact, sans-serif"
HAND = "Marker Felt, Chalkboard SE, sans-serif"
MONO = "Menlo, Monaco, monospace"

MAC = RUBY_PLATFORM.include?("darwin")
DATA_DIR = if MAC
  File.join(Dir.home, "Library", "Application Support", "Dance Dance Monkeypatch")
else
  File.join(ENV.fetch("XDG_DATA_HOME", File.join(Dir.home, ".local", "share")), "dance_dance_monkeypatch")
end
CACHE_DIR = if MAC
  File.join(Dir.home, "Library", "Caches", "Dance Dance Monkeypatch")
else
  File.join(ENV.fetch("XDG_CACHE_HOME", File.join(Dir.home, ".cache")), "dance_dance_monkeypatch")
end
SAVE_FILE = File.join(DATA_DIR, "save.json")

LEVELS = [
  { id: "mild", name: "mild", blurb: "quarter notes. a nice walk in the park.", rgb: LANE_RGB[1], drain: 3, ghost: 0.0 },
  { id: "chunky", name: "chunky", blurb: "eighth notes and bacon. light peril.", rgb: LANE_RGB[2], drain: 5, ghost: 0.6 },
  { id: "unhinged", name: "UNHINGED", blurb: "every note. jumps. nil mines. no mercy.", rgb: LANE_RGB[0], drain: 8, ghost: 1.2 },
].freeze

WINDOWS = [0.05, 0.10, 0.15].freeze # seconds either side of the beat for CHUNKY, CRISPY and raw
JUDGEMENTS = ["CHUNKY!", "CRISPY", "raw"].freeze
POINTS = [300, 200, 100].freeze
GRADES = [
  [0.95, "CHUNKY BACON", LANE_RGB[0]], [0.88, "CRISPY", LANE_RGB[2]], [0.78, "SIZZLING", LANE_RGB[3]],
  [0.65, "RAW", LANE_RGB[1]], [0.0, "nil", NIL_RGB],
].freeze
CLICK_BPM = 100
SKY_BANDS = 12
CLICK_BEATS = 24
LANE_KEYS = {
  left: 0, "d" => 0, "D" => 0, down: 1, "f" => 1, "F" => 1,
  up: 2, "j" => 2, "J" => 2, right: 3, "k" => 3, "K" => 3,
}.freeze

# Each section of a song names one of these; the playfield bends into it on the downbeat.
# The third part is what the robot reads aloud while it happens.
PATCHES = {
  highway: ["Field.new(gravity: 1)", "#<Field straight and narrow>", "field dot new. gravity one."],
  drunk: ["notes.each(&:wobble!)", "#<Enumerator: tipsy>", "notes dot each. wobble."],
  radial: ["class Field; prepend Radial; end", "Field  # it's round now", "prepend radial."],
  reverse: ["def gravity = -1", ":gravity  # down is up", "gravity equals minus one."],
  spiral: ["Field.prepend(Spiral).spin!", "#<Field dizzy>", "spin. bang."],
  tunnel: ["include Perspective  # 3D, basically", "#<Field vanishing>", "include perspective."],
  sideways: ["field.rotate!(90)", "#<Field on its side>", "rotate ninety. bang."],
  shuffle: ["def lanes = super.shuffle", "[:who, :even, :knows]", "lanes equals super dot shuffle."],
  spin: ["field.instance_eval { @spin = 1 }", "1  # oh no", "instance eval. spin equals one. oh no."],
  chaos: ["GC.disable; eval(CHAOS)", "nil  # good luck", "G C dot disable. eval chaos. good luck."],
}.freeze
GLITCHES = { "M" => "W", "O" => "0", "N" => "И", "K" => "<", "E" => "3", "Y" => "¥", "P" => "?", "A" => "4", "T" => "7", "C" => "(", "H" => "#" }.freeze

SKIES = {
  highway: ["#170a2a", "#3a1257"], drunk: ["#1d0b2e", "#5a1846"], radial: ["#06222b", "#1d0f45"],
  reverse: ["#2a0612", "#4d1030"], spiral: ["#2b0636", "#0d1a4a"], tunnel: ["#04041a", "#2d0b4e"],
  sideways: ["#0b2018", "#1c0f3a"], shuffle: ["#2a1306", "#3d0f3f"], spin: ["#0f0a33", "#3b0a3f"],
  chaos: ["#000000", "#2b0010"],
}.freeze
CHAOS_SKIES = [["#3b0018", "#000000"], ["#00203b", "#100020"], ["#2b2b00", "#200010"], ["#002b10", "#10001f"]].freeze

FOX_LINES = {
  title: [
    "pick a song. they're all made of bacon.",
    "this game monkeypatches itself. sorry in advance.",
    "Space is bacon. don't ask why. ask why not.",
    "we wore our shoes. the red ones. for you.",
    "arrows, or D F J K. both correct. nothing else is.",
    "see a nil? leave it alone. it's resting.",
    "press A and we'll play it for you. we're very good.",
    "the timing feels off? press C. we'll tune our ears.",
  ],
  loading: [
    "we're writing the song by hand. one sample at a time.",
    "every wave is a little Ruby block. it takes a sec.",
    "tuning the bloopsaphone. it's mostly squares.",
  ],
  start: ["ok ok ok. arrows. bacon. go.", "it's straight for now. for now.", "deep breath. shoes on. go."],
  patch: {
    highway: "nice and straight. suspicious.",
    drunk: "the notes had some ruby. a lot of ruby.",
    radial: "it's round now?? who let it be round",
    reverse: "gravity was a global variable. was.",
    spiral: "i am going to be sick in my shoe",
    tunnel: "3D!! we're basically a AAA studio now",
    sideways: "tilt your head. no, your other head.",
    shuffle: "who moved my lanes. WHO MOVED MY LANES",
    spin: "make it stop. no. don't. keep going.",
    chaos: "CHAOS IS JUST A HASH WITH NO KEYS",
  },
  hype: [
    "CHUNKY BACON!!", "chunky. bacon.", "your feet are Enumerable", "that was so idiomatic",
    "certified poignant", "you're a stomp-based lifeform", "we're crying. it's fine.",
  ],
  miss: [
    "nil.", "that note is a ghost now", "we'll call that jazz", "it's fine. we forgive you. mostly.",
    "undefined method `hit' for you", "a rescue clause would be nice",
  ],
  mine: ["you stepped on a nil!!", "NoMethodError for NilClass", "that was nil. you can't hit nil."],
  ghost: ["what are you pressing", "there's nothing there, friend", "air drums! very nice"],
  low: ["sanity low. relatable.", "breathe. in a loop.", "begin; dance; rescue; dance; end"],
  fail: ["your shoes were garbage collected.", "sanity exhausted. so are we."],
  clear: ["you did it!! our little stomper!", "not flawless. but chunky. very chunky.", "the elf would be proud. probably."],
  full: ["FULL COMBO. CHUNKY. BACON.", "every note. EVERY NOTE."],
  auto: ["watch and learn. mostly watch.", "we've been practising since 2005."],
  why: [
    "why? because chunky bacon. that's why.",
    "someone left us these shoes. we wore them.",
    "somewhere, a cartoon fox is still shouting.",
    "the guide was poignant. this game is just loud.",
  ],
}.freeze

# The songs. A phrase is bars of notes split by "|", each "pitch:length" in sixteenths (two
# when left out), "r" a rest, and every bar adds up to sixteen. :arp16 runs up and down the
# chords in sixteenths instead. A section's patch is the monkeypatch its first downbeat evals.
SONGS = [
  {
    id: "chunky_bacon", name: "Chunky Bacon", by: "the foxes", bpm: 128,
    phrases: {
      verse: "e5 g5 c6:4 b5 g5 e5:4 | d5 g5 b5:4 a5 g5 d5:4 | c5 e5 a5:4 g5 e5 c5 e5 | f5:4 e5 d5 c5:8 |
              e5 g5 c6:4 b5 g5 e5 g5 | d6:4 b5 g5 d5:4 g5:4 | a5 g5 e5 c5 e5 g5 a5:4 | f5 e5 d5 c5 d5:8",
      chorus: "a5 a5 c6 a5 g5:4 f5:4 | g5 g5 b5 g5 d6:8 | e6 d6 c6 g5 e5 g5 c6:4 | b5 c6 a5:4 e5:4 r:4 |
               a5 a5 c6 a5 g5:4 f5:4 | g5 a5 b5 d6 g6:8 | e6:3 d6:3 c6 d6:3 e6:3 g6 | c6:4 g5 e5 c5:4 r:4",
      bridge: "a4:3 c5:3 e5 a5:3 e5:3 c5 | f4:3 a4:3 c5 f5:3 c5:3 a4 | g4:3 b4:3 d5 g5:3 d5:3 b4 |
               g5 a5 b5 d6 g6 d6 b5 g5",
      outro: "c6:4 g5:4 e5:4 g5:4 | c6:8 r:8",
    },
    sections: [
      { part: "intro", bars: 4, chords: "C G Am F", drums: :half, bass: :pump, arp: :slow, patch: :highway },
      { part: "verse", bars: 8, chords: "C G Am F", lead: :verse, drums: :four, bass: :octave, patch: :drunk },
      { part: "chorus", bars: 8, chords: "F G C Am F G C C", lead: :chorus, drums: :four, bass: :octave, arp: :fast, patch: :radial },
      { part: "bridge", bars: 4, chords: "Am F G G", lead: :bridge, drums: :half, bass: :pump, arp: :slow, patch: :reverse },
      { part: "chorus", bars: 8, chords: "F G C Am F G C C", transpose: 2, lead: :chorus, drums: :four, bass: :octave, arp: :fast, patch: :spiral },
      { part: "outro", bars: 2, chords: "C C", transpose: 2, lead: :outro, drums: :half, bass: :pump, patch: :tunnel },
    ],
  },
  {
    id: "method_missing", name: "method_missing", by: "DJ NoMethodError", bpm: 150,
    phrases: {
      verse: "d5 d5:1 f5:1 a5 d5 c6 a5 f5 e5 | d5 d5:1 f5:1 a5 d6:4 c6 a5 g5 | f5 d5 bb4 d5 f5 bb5:4 a5 |
              g5 e5 c5 e5 g5 c6:4 bb5 | d5 d5:1 f5:1 a5 d5 c6 a5 f5 e5 | d5 d5:1 f5:1 a5 d6 f6 e6 d6 c6 |
              d6 bb5 f5 bb5 d6 f6 d6 bb5 | c#6 a5 e5 a5 c#6 e6 g6:4",
      chorus: "f6:4 d6 bb5 c6:4 d6:4 | e6:4 c6 g5 e6 f6 g6:4 | a6:6 f6 d6:4 a5:4 | d6 e6 f6 e6 d6 c6 a5:4 |
               f6:4 d6 bb5 c6:4 d6:4 | e6:4 g6 e6 c6:4 e6:4 | c#6 e6 a6:4 g6 e6 c#6:4 | a5 c#6 e6 a6 r:8",
      outro: "d6:4 a5:4 f5:4 a5:4 | d6:8 r:8",
    },
    sections: [
      { part: "intro", bars: 4, chords: "Dm Dm Bb A", drums: :pulse, bass: :octave, arp: :fast, patch: :highway },
      { part: "verse", bars: 8, chords: "Dm Dm Bb C Dm Dm Bb A", lead: :verse, drums: :drive, bass: :octave, patch: :shuffle },
      { part: "chorus", bars: 8, chords: "Bb C Dm Dm Bb C A A", lead: :chorus, drums: :four, bass: :octave, arp: :fast, patch: :radial },
      { part: "drop", bars: 4, chords: "Gm Gm A A", drums: :drive, bass: :sync, patch: :sideways },
      { part: "riff", bars: 8, chords: "Dm Bb C A", lead: :arp16, drums: :drive, bass: :octave, patch: :tunnel },
      { part: "chorus", bars: 8, chords: "Bb C Dm Dm Bb C A A", transpose: 1, lead: :chorus, drums: :four, bass: :octave, arp: :fast, patch: :spin },
      { part: "outro", bars: 2, chords: "Dm Dm", transpose: 1, lead: :outro, drums: :half, bass: :pump, patch: :reverse },
    ],
  },
  {
    id: "eval_chaos", name: "eval(CHAOS)", by: "an elf, holding a ham", bpm: 172,
    phrases: {
      verse: "e5:1 g5:1 b5:1 e6:1 b5:1 g5:1 e5 r e5 g5 b5 | c5:1 e5:1 g5:1 c6:1 g5:1 e5:1 c5 r c6 b5 g5 |
              d5:1 g5:1 b5:1 d6:1 b5:1 g5:1 d5 r d6 e6 d6 | f#5 a5 d6 f#6 e6 d6 a5:4 |
              e5:1 g5:1 b5:1 e6:1 b5:1 g5:1 e5 r e5 g5 b5 | c5:1 e5:1 g5:1 c6:1 g5:1 e5:1 c5 r c6 b5 g5 |
              d#6 b5 f#5 b5 d#6 f#6 a6 f#6 | b6:4 a6 f#6 d#6 b5 f#5:4",
      chorus: "g6:4 e6 c6 g5 c6 e6:4 | f#6:4 d6 a5 f#5 a5 d6:4 | e6 g6 b6:4 a6 g6 e6:4 | b5 e6 g6 e6 b5 g5 e5:4 |
               g6:4 e6 c6 g5 c6 e6:4 | a6:4 f#6 d6 a5 d6 f#6:4 | b6 a6 f#6 d#6 f#6 a6 b6:4 |
               b6:1 a6:1 f#6:1 d#6:1 b5:1 a5:1 f#5:1 d#5:1 b4:8",
      outro: "e6:4 b5:4 g5:4 b5:4 | e6:8 r:8",
    },
    sections: [
      { part: "intro", bars: 4, chords: "Em C G D", drums: :dnb, bass: :octave, arp: :fast, patch: :tunnel },
      { part: "verse", bars: 8, chords: "Em C G D Em C B B", lead: :verse, drums: :dnb, bass: :octave, patch: :spiral },
      { part: "chorus", bars: 8, chords: "C D Em Em C D B B", lead: :chorus, drums: :dnb, bass: :octave, arp: :fast, patch: :reverse },
      { part: "chaos", bars: 8, chords: "Em C Am B", lead: :arp16, drums: :dnb, bass: :octave, arp: :fast, patch: :chaos },
      { part: "breakdown", bars: 4, chords: "C C B B", drums: :half, bass: :pump, patch: :sideways },
      { part: "chorus", bars: 8, chords: "C D Em Em C D B B", transpose: 2, lead: :chorus, drums: :dnb, bass: :octave, arp: :fast, patch: :shuffle },
      { part: "outro", bars: 2, chords: "Em Em", transpose: 2, lead: :outro, drums: :half, bass: :pump, patch: :highway },
    ],
  },
].freeze

module Pitch
  CLASSES = {
    "c" => 0, "c#" => 1, "db" => 1, "d" => 2, "d#" => 3, "eb" => 3, "e" => 4, "f" => 5, "f#" => 6,
    "gb" => 6, "g" => 7, "g#" => 8, "ab" => 8, "a" => 9, "a#" => 10, "bb" => 10, "b" => 11,
  }.freeze
  SHAPES = { "" => [0, 4, 7], "m" => [0, 3, 7], "7" => [0, 4, 7, 10], "m7" => [0, 3, 7, 10], "sus4" => [0, 5, 7] }.freeze
  Chord = Struct.new(:root, :shape)

  module_function

  def midi(name)
    match = name.match(/\A([a-g][#b]?)(\d)\z/) or raise ArgumentError, "#{name.inspect} is not a note"
    CLASSES.fetch(match[1]) + 12 * (match[2].to_i + 1)
  end

  def hz(midi) = 440.0 * 2**((midi - 69) / 12.0)

  def chord(name, shift = 0)
    match = name.match(/\A([A-G][#b]?)(.*)\z/) or raise ArgumentError, "#{name.inspect} is not a chord"
    Chord.new((CLASSES.fetch(match[1].downcase) + shift) % 12, SHAPES.fetch(match[2]))
  end
end

# A song laid out as events on a grid of sixteenth notes, after a bar of sticks counting in.
class Arrangement
  BAR = 16
  DRUMS = {
    half: { kick: "x.........x.....", snare: "........x.......", hat: "x...x...x...x..." },
    four: { kick: "x...x...x...x...", snare: "....x.......x...", hat: "..o...o...o...o." },
    pulse: { kick: "x...x...x...x...", hat: "x.x.x.x.x.x.x.x." },
    drive: { kick: "x..x..x.x..x..x.", snare: "....x.......x...", hat: "xxxxxxxxxxxxxxxx" },
    dnb: { kick: "x.........x.....", snare: "....x.......x...", hat: "x.xxx.xxx.xxx.xx" },
  }.freeze
  FILL = "....x...x.x.xxxx"
  BASS = {
    pump: Array.new(8) { |i| [i * 2, 0, 2] },
    octave: Array.new(8) { |i| [i * 2, i.odd? ? 12 : 0, 2] },
    sync: [[0, 0, 3], [3, 0, 3], [6, 12, 2], [8, 0, 3], [11, 0, 3], [14, 7, 2]],
  }.freeze
  RUN = [0, 1, 2, 3, 4, 5, 4, 3, 2, 3, 4, 5, 4, 3, 2, 1].freeze
  Section = Struct.new(:part, :patch, :first_step, :last_step, :lead)

  attr_reader :song, :events, :sections, :step_seconds, :steps

  def initialize(song)
    @song = song
    @step_seconds = 15.0 / song[:bpm]
    @events = []
    @sections = []
    4.times { |beat| add(beat * 4, :stick, beat.zero?, 1) }
    bar = 1
    song[:sections].each do |section|
      lay_out(section, bar * BAR)
      bar += section[:bars]
    end
    @steps = bar * BAR
    @events.sort_by! { |step, voice| [step, voice.to_s] }
  end

  def seconds = @steps * @step_seconds + 1.5
  def time_of(step) = step * @step_seconds
  def beat_at(time) = time / (@step_seconds * 4)
  def section_at(step) = @sections.reverse_each.find { |s| s.first_step <= step } || @sections.first

  def within(section, voices)
    @events.select { |step, voice| voices.include?(voice) && step >= section.first_step && step < section.last_step }
  end

  private

  def add(step, voice, arg, length)
    @events << [step, voice, arg, length]
  end

  def lay_out(section, first)
    shift = section.fetch(:transpose, 0)
    chords = section[:chords].split.map { |name| Pitch.chord(name, shift) }
    bars = section[:bars]
    @sections << Section.new(section[:part], section[:patch], first, first + bars * BAR, !section[:lead].nil?)
    add(first, :crash, nil, BAR)
    bars.times do |i|
      step = first + i * BAR
      chord = chords[i % chords.size]
      drums(section[:drums], step, bars >= 4 && i == bars - 1)
      root = 40 + (chord.root - 4) % 12
      BASS.fetch(section[:bass]).each { |at, up, length| add(step + at, :bass, root + up, length) }
      add(step, :arp, [chord, section[:arp]], BAR) if section[:arp]
    end
    melody(section[:lead], first, bars * BAR, chords, shift) if section[:lead]
  end

  def drums(style, step, fill)
    DRUMS.fetch(style).each do |voice, hits|
      hits = FILL if fill && voice == :snare
      hits.each_char.with_index do |mark, i|
        add(step + i, mark == "o" ? :open_hat : voice, nil, 1) unless mark == "."
      end
    end
  end

  def melody(name, first, total, chords, shift)
    notes = name == :arp16 ? arpeggios(total / BAR, chords) : phrase(name, shift)
    step = 0
    notes.cycle do |midi, length|
      break if step >= total

      add(first + step, :lead, midi, [length, total - step].min) if midi
      step += length
    end
  end

  def phrase(name, shift)
    @song[:phrases].fetch(name).split("|").each_with_index.flat_map do |bar, i|
      notes = bar.split.map do |token|
        pitch, length = token.split(":")
        [pitch == "r" ? nil : Pitch.midi(pitch) + shift, (length || 2).to_i]
      end
      steps = notes.sum(&:last)
      raise ArgumentError, "#{@song[:name]}: #{name} bar #{i + 1} lasts #{steps} sixteenths, not #{BAR}" unless steps == BAR

      notes
    end
  end

  def arpeggios(bars, chords)
    Array.new(bars) do |i|
      chord = chords[i % chords.size]
      tones = chord.shape.first(3).map { |interval| 64 + (chord.root - 4) % 12 + interval }
      tones += tones.map { |midi| midi + 12 }
      RUN.map { |k| [tones[k], 1] }
    end.flatten(1)
  end
end

# A small chiptune synthesizer: every distinct note is worked out once as a list of samples,
# mixed onto the song's timeline, and the whole song written as one 16-bit WAV.
class Chip
  RATE = 22_050
  VERSION = 2
  PEAK = 0.3
  GAIN = {
    kick: 0.7, snare: 0.42, hat: 0.15, open_hat: 0.12, crash: 0.1, stick: 0.45,
    bass: 0.36, arp: 0.12, lead: 0.32,
  }.freeze

  def self.header(bytes)
    ["RIFF", 36 + bytes, "WAVE", "fmt ", 16, 1, 1, RATE, RATE * 2, 2, 16, "data", bytes].pack("a4Va4a4VvvVVvva4V")
  end

  def self.store(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite("#{path}.tmp", header(data.bytesize) + data)
    File.rename("#{path}.tmp", path)
    path
  end

  # A click on every beat, louder on the one, for tuning the timing.
  def self.click_track(path, bpm, beats)
    chip = new(nil)
    spacing = 60.0 / bpm
    mix = Array.new(((beats * spacing + 0.5) * RATE).ceil, 0.0)
    beats.times { |beat| chip.add(mix, chip.stick(beat % 4 == 0), (beat * spacing * RATE).round) }
    store(path, mix.map { |sample| (sample * 32_767).round.clamp(-32_768, 32_767) }.pack("s<*"))
  end

  def initialize(arrangement)
    @arr = arrangement
    @noise = Random.new(11)
    @sounds = {}
  end

  def file_name = "#{@arr.song[:id]}-#{Digest::SHA1.hexdigest([VERSION, @arr.song].inspect)[0, 12]}.wav"

  # Renders the song into `path`, calling the block with how far along it is now and then.
  def write(path, &progress)
    Chip.store(path, render(&progress))
  end

  def render(&progress)
    @progress = progress
    @slice = clock
    size = (@arr.seconds * RATE).ceil
    mix = Array.new(size, 0.0)
    lead = Array.new(size, 0.0)
    events = @arr.events
    events.each_with_index do |(step, voice, arg, length), i|
      add(voice == :lead ? lead : mix, sound(voice, arg, length), (@arr.time_of(step) * RATE).round)
      report(0.7 * i / events.size)
    end
    echo(lead, (@arr.step_seconds * 3 * RATE).round)
    merge(mix, lead)
    finish(mix)
  end

  def add(into, samples, start)
    i = 0
    n = [samples.size, into.size - start].min
    while i < n
      into[start + i] += samples[i]
      i += 1
    end
  end

  def stick(accent = false)
    tone(0.06) { |t| (Math.sin(2 * Math::PI * 1650 * t) * 0.75 + noise * 0.25) * Math.exp(-t * 70) * (accent ? 1.0 : 0.55) }
  end

  private

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def report(fraction)
    return unless @progress && clock - @slice > 0.012

    @progress.call(fraction)
    @slice = clock
  end

  def sound(voice, arg, length)
    @sounds[[voice, arg, length]] ||= begin
      seconds = length * @arr.step_seconds
      samples = case voice
                when :lead then lead_note(arg, seconds)
                when :bass then bass_note(arg, seconds)
                when :arp then arp_bar(*arg, seconds)
                when :stick then stick(arg)
                else send(voice)
                end
      gain = GAIN.fetch(voice)
      samples.map! { |sample| sample * gain }
    end
  end

  def tone(seconds)
    Array.new((seconds * RATE).round) { |i| yield i.fdiv(RATE) }
  end

  def envelope(t, seconds, attack, release)
    return t / attack if t < attack

    left = seconds - t
    left < release ? [left / release, 0.0].max : 1.0
  end

  def noise = @noise.rand * 2 - 1

  def kick
    phase = 0.0
    tone(0.32) do |t|
      phase += (48 + 130 * Math.exp(-t * 32)) / RATE
      Math.sin(2 * Math::PI * phase) * Math.exp(-t * 7.5) + noise * Math.exp(-t * 300) * 0.3
    end
  end

  def snare
    tone(0.22) do |t|
      body = 0.65 * noise * Math.exp(-t * 17) + 0.5 * Math.sin(2 * Math::PI * 185 * t) * Math.exp(-t * 26)
      body * envelope(t, 0.22, 0.001, 0.02)
    end
  end

  def hat = bright(0.05, 75)
  def open_hat = bright(0.26, 11)
  def crash = bright(1.1, 3.2)

  # Only the change from one noise sample to the next, which keeps the high end and drops the rest.
  def bright(seconds, decay)
    last = 0.0
    tone(seconds) do |t|
      now = noise
      high = now - last
      last = now
      high * 0.5 * Math.exp(-t * decay) * envelope(t, seconds, 0.001, 0.01)
    end
  end

  # A four-bit triangle, the NES way, with a little square on top so laptop speakers can hear it.
  def bass_note(midi, seconds)
    step = Pitch.hz(midi) / RATE
    phase = soft = 0.0
    tone(seconds) do |t|
      phase = (phase + step) % 1.0
      triangle = phase < 0.5 ? phase * 4 - 1 : 3 - phase * 4
      raw = 0.7 * ((triangle * 7.5).round / 7.5) + 0.35 * (phase < 0.25 ? 0.75 : -0.25)
      soft += (raw - soft) * 0.3
      soft * envelope(t, seconds, 0.003, 0.025) * (0.75 + 0.25 * Math.exp(-t * 10))
    end
  end

  # A pulse whose width narrows as the note goes on, with vibrato that arrives late.
  def lead_note(midi, seconds)
    hz = Pitch.hz(midi)
    phase = soft = 0.0
    tone(seconds) do |t|
      wobble = t > 0.14 ? Math.sin(2 * Math::PI * 5.6 * t) * 0.007 * [(t - 0.14) * 5, 1].min : 0.0
      phase = (phase + hz * (1 + wobble) / RATE) % 1.0
      duty = 0.5 - 0.3 * [t / 0.4, 1].min
      raw = phase < duty ? 1 - duty : -duty
      soft += (raw - soft) * 0.5
      soft * 1.6 * envelope(t, seconds, 0.004, 0.03) * (0.7 + 0.3 * Math.exp(-t * 6))
    end
  end

  # The chord's notes one after another, so fast they blur into a chord: the chiptune trick.
  def arp_bar(chord, speed, seconds)
    hops = (chord.shape.map { |interval| 60 + chord.root + interval } << 72 + chord.root).map { |midi| Pitch.hz(midi) / RATE }
    slice = @arr.step_seconds * (speed == :fast ? 0.5 : 1.0)
    phase = soft = 0.0
    tone(seconds) do |t|
      k = (t / slice).floor
      phase = (phase + hops[k % hops.size]) % 1.0
      raw = phase < 0.125 ? 0.875 : -0.125
      soft += (raw - soft) * 0.55
      soft * 2 * (0.45 + 0.55 * Math.exp(-(t - k * slice) * 28)) * envelope(t, seconds, 0.002, 0.01)
    end
  end

  # Feeds the lead back into itself three sixteenths later, so every note echoes and fades.
  def echo(lead, delay)
    i = delay
    n = lead.size
    while i < n
      lead[i] += lead[i - delay] * 0.3
      i += 1
      report(0.7 + 0.1 * i / n) if (i % 20_000).zero?
    end
  end

  def merge(mix, lead)
    i = 0
    n = mix.size
    while i < n
      mix[i] += lead[i]
      i += 1
      report(0.8 + 0.05 * i / n) if (i % 20_000).zero?
    end
  end

  # tanh rounds off the loudest moments rather than clipping them; then the peak is set to PEAK.
  def finish(mix)
    low, high = mix.minmax
    scale = PEAK / [Math.tanh([low.abs, high.abs].max), 1e-6].max * 32_767
    out = String.new(encoding: Encoding::BINARY)
    mix.each_slice(RATE / 2).with_index do |slice, i|
      out << slice.map { |sample| (Math.tanh(sample) * scale).round }.pack("s<*")
      report(0.85 + 0.15 * i * RATE / 2 / mix.size)
    end
    out
  end
end

# Which notes to play, worked out from the song itself, so the chart always moves with the
# music: melodies climb the lanes with their pitch, and drums fill in where nobody sings.
class Chart
  Note = Struct.new(:time, :lane, :kind, :step, :judged, :missed, :sprite)
  GAP = { "mild" => 4, "chunky" => 2, "unhinged" => 1 }.freeze
  RHYTHM = { kick: [1, 2], snare: [0, 3], hat: [3, 2, 1, 0], open_hat: [3, 2, 1, 0] }.freeze
  RANK = { kick: 0, snare: 1, hat: 2, open_hat: 2 }.freeze

  attr_reader :notes

  def initialize(arrangement, level)
    @arr = arrangement
    @level = level
    @random = Random.new(arrangement.song[:id].sum)
    bacon = @arr.sections.map(&:first_step) << @arr.sections.last.first_step + Arrangement::BAR
    taps = @arr.sections.flat_map { |section| section.lead ? melody(section) : rhythm(section) }
    taps.reject! { |step, _| bacon.any? { |b| (step - b).abs < [GAP[level], 2].max } }
    taps.concat(jumps(taps)) if level == "unhinged"
    mines = level == "unhinged" ? mines(taps, bacon) : []
    @notes = [
      *taps.map { |step, lane| note(step, lane, :tap) },
      *bacon.map { |step| note(step, nil, :bacon) },
      *mines.map { |step, lane| note(step, lane, :mine) },
    ].sort_by { |n| [n.step, n.lane || -1] }
  end

  def scored = @notes.count { |n| n.kind != :mine }

  private

  def note(step, lane, kind) = Note.new(@arr.time_of(step), lane, kind, step, false, false, nil)

  def thin(hits)
    last = -100
    hits.select do |step, _|
      next false if @level != "unhinged" && step.odd?
      next false if step - last < GAP.fetch(@level)

      last = step
    end
  end

  def melody(section)
    lead = @arr.within(section, [:lead]).map { |step, _, midi| [step, midi] }
    pitches = lead.map(&:last).uniq.sort
    last_lane = last_midi = last_step = nil
    thin(lead).map do |step, midi|
      lane = pitches.index(midi) * 4 / pitches.size
      if lane == last_lane && (midi != last_midi || step - last_step < 2)
        way = midi < last_midi ? -1 : 1
        lane = (0..3).cover?(lane + way) ? lane + way : lane - way
      end
      last_lane, last_midi, last_step = lane, midi, step
      [step, lane]
    end
  end

  def rhythm(section)
    voices = @level == "unhinged" ? RHYTHM.keys : %i[kick snare]
    hits = @arr.within(section, voices).group_by(&:first).map { |step, group| [step, group.min_by { |e| RANK[e[1]] }[1]] }
    turns = Hash.new(0)
    thin(hits.sort).map do |step, voice|
      lanes = RHYTHM[voice]
      turns[voice] += 1
      [step, lanes[turns[voice] % lanes.size]]
    end
  end

  def jumps(taps)
    taps.filter_map { |step, lane| [step, 3 - lane] if (step % Arrangement::BAR).zero? }
  end

  def mines(taps, bacon)
    busy = Hash.new { |hash, lane| hash[lane] = [] }
    taps.each { |step, lane| busy[lane] << step }
    @arr.sections.select(&:lead).flat_map do |section|
      (section.first_step...section.last_step).step(2).filter_map do |step|
        next unless @random.rand < 0.09
        next if bacon.any? { |b| (step - b).abs < 6 }

        lane = [0, 1, 2, 3].shuffle(random: @random).find { |l| busy[l].none? { |s| (s - step).abs <= 2 } }
        [step, lane] if lane
      end
    end
  end
end

# Where a lane's note sits when it is `d` beats from its ring, for every shape the field takes.
module Field
  CX, CY = 480, 318
  GAP = 84
  BEAT_PX = 118
  LOW, HIGH = 548, 134
  RING = 70
  ANGLES = [Math::PI, Math::PI / 2, -Math::PI / 2, 0.0].freeze # ← ↓ ↑ → as directions from the centre

  module_function

  def point(mode, lane, d, beat, slots)
    case mode
    when :highway then [lane_x(lane), LOW - d * BEAT_PX, 1.0]
    when :reverse then [lane_x(lane), HIGH + d * BEAT_PX, 1.0]
    when :drunk
      sway = Math.sin(d * 1.3 + beat * Math::PI / 2 + lane * 0.8) * (16 + 30 * [d.abs / 2, 1].min)
      [lane_x(lane) + sway, LOW - d * BEAT_PX, 1.0]
    when :shuffle then [CX + (slots[lane] - 1.5) * GAP, LOW - d * BEAT_PX, 1.0]
    when :radial then around(ANGLES[lane], RING + d * 100)
    when :spin then around(ANGLES[lane] + beat * 0.35, RING + d * 100)
    when :spiral then around(ANGLES[lane] + d * 0.7 + beat * 0.1, RING + d * 92)
    when :tunnel
      s = 1.0 / (1 + [d, -0.4].max * 0.55)
      [CX + (lane - 1.5) * 128 * s, 132 + (LOW - 132) * s, s]
    when :sideways then [236 + d * BEAT_PX, 280 + (lane - 1.5) * 72, 1.0]
    when :chaos
      twist = d * 0.9 * Math.sin(beat * 0.4) + beat * 0.5
      around(ANGLES[lane] + twist, (RING + d * 96) * (1 + 0.12 * Math.cos(beat * Math::PI)))
    end
  end

  def around(angle, r) = [CX + Math.cos(angle) * r, CY + Math.sin(angle) * r, 1.0]
  def lane_x(lane) = CX + (lane - 1.5) * GAP
end

# Arrows drawn as shapes around (0, 0), so `move` puts their middle where it is told.
module Arrow
  LEFT = [[-11, 0], [1, -10], [1, -4], [11, -4], [11, 4], [1, 4], [1, 10]].freeze

  def self.points(lane)
    LEFT.map do |x, y|
      case lane
      when 0 then [x, y]
      when 1 then [y, -x]
      when 2 then [y, x]
      else [-x, y]
      end
    end
  end

  def self.draw(app, lane, scale = 1.0)
    points = self.points(lane).map { |x, y| [x * scale, y * scale] }
    app.shape do
      app.move_to(*points.first)
      points.drop(1).each { |x, y| app.line_to(x, y) }
      app.line_to(*points.first)
    end
  end
end

class Jukebox
  attr_accessor :muted
  attr_reader :last_file

  def initialize
    @dir = Dir.mktmpdir("monkeypatch-jukebox")
    at_exit do
      stop
      FileUtils.rm_rf(@dir)
    end
  end

  # Plays a WAV in the background from `from` seconds in, cutting a copy of its tail to get there.
  def play(path, from = 0.0)
    stop
    return if muted

    @last_file = from > 0.005 ? tail(path, from) : path
    @pid = spawn("afplay", @last_file, out: File::NULL, err: File::NULL)
    Process.detach(@pid)
  rescue SystemCallError
    @pid = nil # no afplay here (not a Mac): the game keeps time without it
  end

  def stop
    Process.kill("TERM", @pid) if @pid
  rescue SystemCallError
    nil
  ensure
    @pid = nil
  end

  private

  def tail(path, from)
    wav = File.binread(path)
    skip = [(from * Chip::RATE).floor * 2, wav.bytesize - 44].min
    data = wav.byteslice(44 + skip, wav.bytesize)
    Chip.store(File.join(@dir, "from-#{(from * 1000).round}.wav"), data)
  end
end

class Voices
  attr_accessor :quiet

  def initialize
    at_exit { hush }
  end

  def say(line, voice, interrupt: false)
    hush if interrupt
    return if quiet || @waiter&.alive?

    @pid = spawn("say", "-v", voice, "[[volm 0.3]] #{line}", out: File::NULL, err: File::NULL)
    @waiter = Process.detach(@pid)
  rescue SystemCallError
    nil
  end

  def hush
    Process.kill("TERM", @pid) if @waiter&.alive?
  rescue SystemCallError
    nil
  end
end

# A fox in little red shoes, drawn into its own slot so it can bob about in one move.
class Fox
  def initialize(app, left, top, fur:, hat: false)
    @app = app
    @left = left
    @top = top
    @slot = app.stack(left: left, top: top, width: 112, height: 140) { draw(fur, hat) }
    @talk_until = 0
  end

  def talk(seconds, now)
    @talk_until = now + seconds
  end

  def dance(bob, lean, now)
    @slot.move((@left + lean).round, (@top - bob).round)
    open = now < @talk_until && (now * 9).floor.even?
    @mouth.style(hidden: !open) if open != @open
    @open = open
  end

  private

  def draw(fur, hat)
    a = @app
    a.nostroke
    a.oval(62, 70, 46, 22, fill: fur)
    a.oval(92, 68, 18, 20, fill: CREAM)
    a.oval(30, 72, 52, 54, fill: fur)
    a.oval(42, 84, 28, 36, fill: CREAM)
    a.rect(22, 119, 32, 14, 7, fill: SHOE_RED)
    a.rect(58, 119, 32, 14, 7, fill: SHOE_RED)
    a.rect(22, 130, 32, 5, 2, fill: "#ffffff")
    a.rect(58, 130, 32, 5, 2, fill: "#ffffff")
    triangle([[20, 46], [30, 2], [52, 30]], fur)
    triangle([[60, 30], [82, 2], [92, 46]], fur)
    triangle([[28, 34], [32, 12], [44, 30]], DARK)
    triangle([[68, 30], [80, 12], [84, 34]], DARK)
    a.oval(16, 24, 80, 62, fill: fur)
    a.oval(30, 54, 52, 32, fill: CREAM)
    a.oval(37, 45, 10, 12, fill: DARK)
    a.oval(65, 45, 10, 12, fill: DARK)
    a.oval(39, 47, 4, fill: "#ffffff")
    a.oval(67, 47, 4, fill: "#ffffff")
    a.oval(51, 60, 10, 7, fill: DARK)
    @mouth = a.oval(50, 70, 12, 10, fill: "#7a1d2e")
    @mouth.hide
    return unless hat

    a.rect(36, 0, 40, 24, 3, fill: DARK)
    a.rect(36, 14, 40, 5, fill: SHOE_RED)
    a.rect(26, 21, 60, 6, 3, fill: DARK)
  end

  def triangle(points, color)
    a = @app
    shape = a.shape do
      a.move_to(*points[0])
      a.line_to(*points[1])
      a.line_to(*points[2])
      a.line_to(*points[0])
    end
    shape.style(fill: color)
  end
end

class Bubble
  def initialize(app, left, top, width, height, size: 17)
    @app = app
    @slot = app.stack(left: left, top: top, width: width, height: height) do
      app.background CREAM, curve: 16
      @text = app.para "", font: HAND, size: size, stroke: DARK, margin: [14, 10, 14, 0]
    end
  end

  def say(line)
    @text.replace(line)
  end
end

class Candy
  def initialize(app, lane)
    @color = app.rgb(*LANE_RGB[lane])
    @grey = app.rgb(*NIL_RGB, 0.6)
    app.nostroke
    @body = app.oval(0, 0, 44, center: true, fill: @color, stroke: app.rgb(255, 255, 255, 0.85), strokewidth: 3)
    @shine = app.oval(0, 0, 12, center: true, fill: app.rgb(255, 255, 255, 0.7))
    @arrow = Arrow.draw(app, lane, 0.95)
    @arrow.style(fill: DARK)
    @parts = [@body, @shine, @arrow]
    @parts.each(&:hide)
    @free = true
    @size = 1.0
  end

  def free? = @free

  def take
    @free = false
    @body.style(fill: @color)
    @parts.each(&:show)
  end

  def place(x, y, s)
    s = [s, 0.25].max
    if (s - @size).abs > 0.01
      @size = s
      @body.style(left: x, top: y, width: 44 * s, height: 44 * s)
      @shine.style(left: x - 8 * s, top: y - 9 * s, width: 12 * s, height: 12 * s)
      @arrow.style(hidden: s < 0.6)
    else
      @body.style(left: x, top: y)
      @shine.style(left: x - 8 * s, top: y - 9 * s)
    end
    @arrow.move(x.round, y.round + 1) if s >= 0.6
  end

  def dim
    @body.style(fill: @grey)
  end

  def release
    @free = true
    @parts.each(&:hide)
  end
end

# A bacon note: a rasher at every lane, all hit at once with Space.
class Rasher
  MEAT = "#c2361f"
  PINK = "#ff8f7f"
  FAT = "#ffe3cf"

  def initialize(app)
    app.nostroke
    @strips = Array.new(4) do
      [app.rect(0, 0, 66, 22, 10, fill: MEAT), app.rect(0, 0, 56, 5, 2, fill: PINK), app.rect(0, 0, 56, 4, 2, fill: FAT)]
    end
    @strips.flatten.each(&:hide)
    @free = true
  end

  def free? = @free

  def take
    @free = false
    @strips.flatten.each(&:show)
  end

  def place_strip(i, x, y, s)
    s = [s, 0.3].max
    meat, pink, fat = @strips[i]
    w = 66 * s
    h = 22 * s
    meat.style(left: x - w / 2, top: y - h / 2, width: w, height: h)
    pink.style(left: x - w / 2 + 5 * s, top: y - h / 2 + 4 * s, width: w - 10 * s, height: 5 * s)
    fat.style(left: x - w / 2 + 5 * s, top: y + 2 * s, width: w - 10 * s, height: 4 * s)
  end

  def dim
    @strips.each { |meat, _, _| meat.style(fill: "#5c4f6e") }
  end

  def release
    @free = true
    @strips.each { |meat, _, _| meat.style(fill: MEAT) }
    @strips.flatten.each(&:hide)
  end
end

# A nil mine: hit its lane while it sits in the ring and something bad happens.
class Mine
  def initialize(app)
    app.nostroke
    @spikes = app.star(0, 0, 9, 22, 13, fill: "#3d3052", stroke: SHOE_RED, strokewidth: 2)
    @core = app.oval(0, 0, 12, center: true, fill: SHOE_RED)
    @parts = [@spikes, @core]
    @parts.each(&:hide)
    @free = true
  end

  def free? = @free

  def take
    @free = false
    @parts.each(&:show)
  end

  def place(x, y, _s)
    @spikes.move(x.round, y.round)
    @core.style(left: x, top: y)
  end

  def dim; end

  def release
    @free = true
    @parts.each(&:hide)
  end
end

Shoes.app(title: "Dance Dance Monkeypatch", width: W, height: H, resizable: false) do
  def now = @clock.call
  def lane_rgb(lane, alpha = 1.0) = rgb(*LANE_RGB[lane], alpha)
  def smooth(k) = k <= 0 ? 0.0 : k >= 1 ? 1.0 : k * k * (3 - 2 * k)
  def commas(n) = n.to_s.reverse.scan(/\d{1,3}/).join(",").reverse

  def load_save
    saved = begin
      JSON.parse(File.read(SAVE_FILE))
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end
    @save = { "offset" => 0.09, "muted" => false, "voices" => true, "best" => {}, "plays" => 0 }.merge(saved)
  end

  def save!
    FileUtils.mkdir_p(DATA_DIR)
    File.write("#{SAVE_FILE}.tmp", JSON.pretty_generate(@save))
    File.rename("#{SAVE_FILE}.tmp", SAVE_FILE)
  end

  def offset = @save["offset"]

  def arrangement(index)
    @arrangements[index] ||= Arrangement.new(SONGS[index])
  end

  def clock_text(seconds) = format("%d:%02d", seconds / 60, seconds % 60)

  def go(screen)
    @screen = screen
    @screen_t0 = now
    @stage.clear { send("build_#{screen}") }
  end

  def fox_line(kind, lines = FOX_LINES[kind])
    line = lines.is_a?(Array) ? lines.sample : lines
    @talker = 1 - (@talker || 0)
    @bubble.say(line)
    @foxes[@talker].talk([line.size * 0.05, 0.8].max, now)
    @tails&.each_with_index { |tail, i| tail.style(hidden: i != @talker) }
    @last_line_at = now
  end

  def shout(line, voice = %w[Fred Junior][@talker || 0], interrupt: false)
    @voices.say(line, voice, interrupt: interrupt)
  end

  def draw_foxes(left, top)
    [Fox.new(self, left, top, fur: "#ff8a2a"), Fox.new(self, left + 104, top, fur: "#f26a1b", hat: true)]
  end

  # The foxes in the bottom left corner, with a bubble over them that points at whoever talks.
  def fox_corner
    @bubble = Bubble.new(self, 12, 406, 280, 74)
    nostroke
    @tails = [64, 168].map do |x|
      tail = shape { move_to x, 479; line_to x + 12, 496; line_to x + 24, 479; line_to x, 479 }
      tail.style(fill: CREAM)
      tail
    end
    @foxes = draw_foxes(8, 498)
  end

  def dance_foxes(beat, wild = 1.0, run = 0)
    t = now
    @foxes.each_with_index do |fox, i|
      bounce = (Math.sin((beat + i * 0.5) * Math::PI).abs * 7 * wild)
      fox.dance(bounce, Math.sin(beat * Math::PI) * 3 * wild + run, t)
    end
  end

  # Every screen but the game paints its own night sky; the game's changes colour with each patch.
  def scenery
    nostroke
    rect 0, 0, W, H, fill: "#170a2a".."#3a1257"
    draw_grid(476)
  end

  def draw_grid(horizon)
    @grid = Array.new(9) { rect(0, horizon, W, 2, fill: rgb(255, 110, 199, 0.13)) }
    15.times do |i|
      line 480 + (i - 7) * 16, horizon, 480 + (i - 7) * 150, H, stroke: rgb(255, 110, 199, 0.11), strokewidth: 1.5
    end
    @horizon = horizon
  end

  def roll_grid(t)
    phase = (t * 0.7) % 1.0
    @grid.each_with_index do |bar, k|
      u = (k + phase) / @grid.size
      bar.style(top: (@horizon + (H - @horizon) * u * u).round)
    end
  end

  # ------------------------------------------------------------------ title

  def build_title
    scenery
    para "DANCE   DANCE", font: DISPLAY, size: 36, stroke: INK, align: "center", left: 0, top: 14, width: W, margin: 0
    widths = [69, 53, 52, 52, 40, 46, 49, 49, 45, 54, 54]
    x = (W - widths.sum - 4 * widths.size) / 2
    @letters = "MONKEYPATCH".chars.each_with_index.map do |letter, i|
      shadow = para letter, font: DISPLAY, size: 96, stroke: "#0b0414", left: x + 5, top: 60, margin: 0
      front = para letter, font: DISPLAY, size: 96, stroke: lane_rgb(i % 4), left: x, top: 55, margin: 0
      spot = x
      x += widths[i] + 4
      [shadow, front, spot]
    end
    para "a rhythm game that monkeypatches itself while you play", font: HAND, size: 20, stroke: MUTED,
      align: "center", left: 0, top: 176, width: W, margin: 0

    @cards = stack(left: 0, top: 222, width: W, height: 160) { draw_cards }
    @pills = stack(left: 0, top: 392, width: W, height: 80) { draw_pills }

    stack left: 28, top: 498, width: 400 do
      [["← →", "pick a song"], ["↑ ↓", "pick a pain level"], ["ENTER", "dance"], ["A", "let the foxes play it"],
       ["C", "calibrate timing"], ["M  V", "mute music / fox voices"]].each do |keys, words|
        para span(keys.ljust(7), stroke: INK), span(words, stroke: MUTED), font: MONO, size: 13, margin: [0, 0, 0, 5]
      end
      @status = para status_line, font: MONO, size: 11, stroke: MUTED, margin: [0, 6, 0, 0]
    end

    @bubble = Bubble.new(self, 420, 508, 286, 74)
    nostroke
    tail = shape { move_to 705, 528; line_to 726, 540; line_to 705, 552; line_to 705, 528 }
    tail.style(fill: CREAM)
    @foxes = draw_foxes(728, 494)
    @tails = nil
    fox_line(:title)
  end

  def status_line
    music = @jukebox.muted ? "music off" : "music on"
    foxes = @voices.quiet ? "foxes quiet" : "foxes loud"
    "#{music} · #{foxes} · timing #{(offset * 1000).round} ms"
  end

  def draw_cards
    SONGS.each_with_index do |song, i|
      chosen = i == @song_index
      color = lane_rgb(i)
      card = stack(left: 70 + i * 280, top: chosen ? 0 : 10, width: 260, height: 148) do
        background(chosen ? rgb(255, 255, 255, 0.14) : rgb(255, 255, 255, 0.05), curve: 18)
        border(chosen ? color : rgb(255, 255, 255, 0.14), strokewidth: chosen ? 3 : 1, curve: 18)
        para song[:name], font: DISPLAY, size: 28, stroke: chosen ? INK : MUTED, margin: [18, 14, 12, 0]
        para "by #{song[:by]}", font: HAND, size: 15, stroke: MUTED, margin: [18, 2, 12, 0]
        para "#{song[:bpm]} BPM · #{clock_text(arrangement(i).seconds)}", font: MONO, size: 12, stroke: color, margin: [18, 8, 12, 0]
        para best_line(song), font: HAND, size: 15, stroke: INK, margin: [18, 8, 12, 0]
      end
      card.click { pick(i, @level_index) }
    end
  end

  def best_line(song)
    best = @save["best"]["#{song[:id]}/#{LEVELS[@level_index][:id]}"]
    return "never danced. yet." unless best

    "best: #{best["grade"]} · #{format("%.1f", best["accuracy"] * 100)}%"
  end

  def draw_pills
    LEVELS.each_with_index do |level, i|
      chosen = i == @level_index
      color = rgb(*level[:rgb])
      pill = stack(left: 214 + i * 182, top: 0, width: 168, height: 44) do
        background(chosen ? color : rgb(255, 255, 255, 0.06), curve: 22)
        border(color, strokewidth: 2, curve: 22) unless chosen
        para level[:name], font: DISPLAY, size: 22, align: "center", stroke: chosen ? DARK : color, margin: [0, 7, 0, 0]
      end
      pill.click { pick(@song_index, i) }
    end
    para LEVELS[@level_index][:blurb], font: HAND, size: 17, stroke: INK, align: "center", left: 0, top: 54, width: W, margin: 0
  end

  def pick(song_index, level_index)
    if song_index == @song_index && level_index == @level_index
      start_song
      return
    end
    @song_index = song_index % SONGS.size
    @level_index = level_index.clamp(0, LEVELS.size - 1)
    @cards.clear { draw_cards }
    @pills.clear { draw_pills }
  end

  def tick_title
    t = now - @screen_t0
    beat = t * 2.0
    roll_grid(t)
    @letters.each_with_index do |(shadow, front, x), i|
      hop = (beat.floor * 7 + 3) % 11 == i ? Math.sin((beat % 1) * Math::PI) * 18 : 0
      y = (55 + Math.sin(t * 4 + i * 0.55) * 6 - hop).round
      front.move(x, y)
      shadow.move(x + 5, y + 5)
    end
    if beat.floor != @title_beat
      @title_beat = beat.floor
      glitch = @title_beat % 6 == 5 ? (@title_beat * 5) % @letters.size : nil
      @letters.each_with_index do |(shadow, front, _), i|
        letter = "MONKEYPATCH"[i]
        letter = GLITCHES[letter] if i == glitch
        front.style(stroke: lane_rgb((i + @title_beat) % 4))
        next if front.text == letter

        front.replace(letter)
        shadow.replace(letter)
      end
    end
    dance_foxes(beat, 0.7)
    fox_line(:title) if t > 2 && now - @last_line_at > 5
  end

  def key_title(key)
    case key
    when :left then pick(@song_index - 1, @level_index)
    when :right then pick(@song_index + 1, @level_index)
    when :up then pick(@song_index, @level_index + 1)
    when :down then pick(@song_index, @level_index - 1)
    when "\n", " " then start_song
    when "a", "A" then start_song(auto: true)
    when "c", "C" then go(:calibrate)
    when "m", "M", "v", "V"
      toggle_sound(key.downcase)
      @status.replace(status_line)
    end
    @typed_keys = "#{@typed_keys}#{key}".chars.last(3).join if key.is_a?(String)
    fox_line(:why) if @typed_keys == "why"
  end

  def toggle_sound(which)
    if which == "m"
      @jukebox.muted = @save["muted"] = !@jukebox.muted
    else
      @voices.quiet = !@voices.quiet
      @save["voices"] = !@voices.quiet
    end
    save!
  end

  # ------------------------------------------------------------------ loading

  def start_song(auto: false)
    @auto = auto
    @arr = arrangement(@song_index)
    @chip = Chip.new(@arr)
    @wav = File.join(CACHE_DIR, @chip.file_name)
    go(File.exist?(@wav) ? :play : :loading)
  end

  def build_loading
    scenery
    song = @arr.song
    para "tuning the bloopsaphone", font: DISPLAY, size: 52, stroke: INK, align: "center", left: 0, top: 170, width: W, margin: 0
    para "writing #{song[:name]} by hand, one sample at a time", font: HAND, size: 20, stroke: MUTED,
      align: "center", left: 0, top: 240, width: W, margin: 0
    nostroke
    rect 230, 296, 500, 22, 11, fill: rgb(255, 255, 255, 0.1)
    @bar = rect 230, 296, 22, 22, 11, fill: lane_rgb(@song_index)
    @percent = para "0%", font: MONO, size: 14, stroke: INK, align: "center", left: 0, top: 330, width: W, margin: 0
    fox_corner
    fox_line(:loading)
    @job = Fiber.new do
      @chip.write(@wav) { |done| Fiber.yield(done) }
      :done
    end
  end

  def tick_loading
    done = @job.resume
    if done == :done
      @job = nil
      go(:play)
      return
    end
    @bar.style(width: (22 + 478 * done).round)
    @percent.replace("#{(done * 100).round}%")
    roll_grid(now - @screen_t0)
    dance_foxes((now - @screen_t0) * 2)
  end

  def key_loading(key)
    go(:title) if key == :escape
  end

  # ------------------------------------------------------------------ play

  def build_play
    level = LEVELS[@level_index]
    @level = level
    @chart = Chart.new(@arr, level[:id])
    @notes = @chart.notes
    @bps = @arr.song[:bpm] / 60.0
    @end_time = @notes.last.time + 2.2

    nostroke
    @sky = Array.new(SKY_BANDS) { |i| rect(0, i * H / SKY_BANDS, W, H / SKY_BANDS + 1, fill: "#170a2a") }
    @stars = Array.new(40) { oval(rand(W), rand(H), rand(1.5..3.5), center: true, fill: rgb(255, 255, 255, 0.3)) }
    @guides = Array.new(4) { |lane| Array.new(6) { oval(0, 0, 7, center: true, fill: lane_rgb(lane, 0.3)) } }

    @receptors = Array.new(4) do |lane|
      glow = oval(0, 0, 52, center: true, fill: lane_rgb(lane, 0.12))
      nofill
      ring = oval(0, 0, 56, center: true, stroke: lane_rgb(lane), strokewidth: 4)
      nostroke
      arrow = Arrow.draw(self, lane, 1.1)
      arrow.style(fill: lane_rgb(lane, 0.9))
      { glow: glow, ring: ring, arrow: arrow }
    end

    @gems = Array.new(4) { |lane| Array.new(12) { Candy.new(self, lane) } }
    @rashers = Array.new(3) { Rasher.new(self) }
    @mines = Array.new(8) { Mine.new(self) }

    nofill
    @bursts = Array.new(8) { { shape: oval(0, 0, 50, center: true, stroke: rgb(255, 255, 255, 0.0), strokewidth: 4), age: 1.0 } }
    nostroke
    @sparks = Array.new(40) { { shape: oval(0, 0, 7, center: true, fill: rgb(255, 255, 255, 0.0)), life: 0.0 } }
    @pops = Array.new(8) do
      { text: para("", font: DISPLAY, size: 24, align: "center", width: 160, left: 0, top: -100, margin: 0), life: 0.0 }
    end

    draw_hud(level)

    fox_corner

    @count = para "", font: DISPLAY, size: 120, stroke: INK, align: "center", left: 0, top: 180, width: W, margin: 0
    @flash = rect(0, 0, W, H, fill: rgb(255, 255, 255, 0.0))
    @flash.hide
    @pause_box = stack(left: 0, top: 0, width: W, height: H) do
      background rgb(10, 4, 20, 0.82)
      para "PAUSED", font: DISPLAY, size: 80, stroke: INK, align: "center", margin: [0, 200, 0, 0]
      para "the foxes are holding very, very still", font: HAND, size: 22, stroke: MUTED, align: "center", margin: [0, 8, 0, 0]
      para "ENTER  keep dancing     ESC  give up", font: MONO, size: 15, stroke: INK, align: "center", margin: [0, 30, 0, 0]
    end
    @pause_box.hide

    reset_play
  end

  def draw_hud(level)
    nostroke
    rect 0, 0, W, 4, fill: rgb(255, 255, 255, 0.08)
    @progress = rect 0, 0, 1, 4, fill: rgb(*level[:rgb])

    stack(left: 14, top: 14, width: 430, height: 78) do
      background rgb(0, 0, 0, 0.42), curve: 10
      @con_old = para "", font: MONO, size: 13, stroke: rgb(255, 255, 255, 0.35), margin: [12, 9, 8, 0]
      @con_new = para "", font: MONO, size: 13, stroke: INK, margin: [12, 3, 8, 0]
      @con_out = para "", font: MONO, size: 13, stroke: rgb(*LANE_RGB[3]), margin: [12, 3, 8, 0]
    end

    stack left: 730, top: 12, width: 214 do
      para "SCORE", font: MONO, size: 11, stroke: MUTED, align: "right", margin: 0
      @score_text = para "0", font: DISPLAY, size: 34, stroke: INK, align: "right", margin: 0
      @acc_text = para "100.0%", font: MONO, size: 13, stroke: MUTED, align: "right", margin: 0
    end
    stack left: 730, top: 120, width: 214 do
      @combo_text = para "", font: DISPLAY, size: 64, stroke: INK, align: "right", margin: 0
      @combo_word = para "", font: HAND, size: 18, stroke: MUTED, align: "right", margin: 0
    end

    who = @auto ? "AUTOPLAY · the foxes are driving" : "#{level[:name]} · #{@arr.song[:name]}"
    para who, font: MONO, size: 12, stroke: rgb(*level[:rgb]), align: "right", left: 704, top: 560, width: 240, margin: 0
    para "sanity", font: HAND, size: 16, stroke: INK, left: 744, top: 580, margin: 0
    rect 744, 606, 200, 12, 6, fill: rgb(255, 255, 255, 0.12)
    @sanity_bar = rect 744, 606, 100, 12, 6, fill: rgb(*LANE_RGB[3])

    @banner = stack(left: 180, top: 150, width: 600, height: 56) do
      background rgb(0, 0, 0, 0.6), curve: 14
      @banner_text = para "", font: MONO, size: 24, stroke: rgb(*LANE_RGB[3]), align: "center", margin: [0, 12, 0, 0]
    end
    @banner.hide
  end

  def reset_play
    @live = []
    @next = 0
    @counts = [0, 0, 0, 0]
    @errors = []
    @mines_hit = 0
    @combo = @best_combo = @score = 0
    @sanity = 70.0
    @slots = [0.0, 1.0, 2.0, 3.0]
    @slot_goal = [0, 1, 2, 3]
    @heat = [0.0] * 4
    @mode = @prev_mode = @arr.sections.first.patch
    @blend_beat = -10
    @section = nil
    @roll_beat = -10
    @shake = 0.0
    @flash_level = 0.0
    @shown = {}
    @paused = false
    @dying = nil
    @last_beat = -1
    @typed = 0
    @last_line_at = now
    @shuffle_bar = nil
    apply_sky(@mode)
    @t0 = now + offset
    @save["plays"] += 1
    @jukebox.play(@wav)
    fox_line(@auto ? :auto : :start)
  end

  def song_time = now - @t0

  def tick_play
    return if @paused

    t = song_time
    beat = @arr.beat_at(t)
    return finish_play(failed: true) if @dying && now > @dying

    advance_patch(beat, (t / @arr.step_seconds).floor)
    @slots.each_index { |lane| @slots[lane] += (@slot_goal[lane] - @slots[lane]) * 0.14 }
    autoplay(t) if @auto
    spawn_notes(t)
    sweep(t)
    place_field(t, beat)
    tick_effects(beat)
    tick_hud(t, beat)
    finish_play if t > @end_time && !@dying
  end

  def advance_patch(beat, step)
    section = @arr.section_at(step)
    if step >= section.first_step && section != @section
      @section = section
      start_patch(section.patch, beat)
    end
    return unless @mode == :shuffle

    bar = (beat / 4).floor
    return if bar.odd? || bar == @shuffle_bar

    @shuffle_bar = bar
    goal = @slot_goal
    goal = [0, 1, 2, 3].shuffle until goal != @slot_goal
    @slot_goal = goal
  end

  def start_patch(mode, beat)
    @prev_mode = @mode
    @mode = mode
    @blend_beat = beat
    @slot_goal = [0, 1, 2, 3] unless mode == :shuffle
    code, result, spoken = PATCHES.fetch(mode)
    @con_old.replace(@con_new.text)
    @prompt = "irb(foxes):#{format("%03d", @arr.sections.index(@section) + 1)}> "
    @patch_code = code
    @patch_result = "=> #{result}"
    @typed = 0
    @con_out.replace("")
    @banner_text.replace(code)
    @banner.move(180, mode == :reverse ? 300 : 150)
    @banner.show
    @banner_until = now + 1.6
    @flash_level = 0.55
    @shake = 10
    apply_sky(mode)
    fox_line(:patch, FOX_LINES[:patch][mode])
    shout(spoken, "Zarvox", interrupt: true)
  end

  # Solid bands rather than one gradient: a full-window gradient costs the painter twice as much
  # every frame, and the steps suit the chiptune.
  def apply_sky(mode)
    paint_sky(*SKIES.fetch(mode))
  end

  def paint_sky(top, bottom)
    from = top.delete("#").scan(/../).map(&:hex)
    to = bottom.delete("#").scan(/../).map(&:hex)
    @sky.each_with_index do |band, i|
      k = i.fdiv(SKY_BANDS - 1)
      band.style(fill: rgb(*from.zip(to).map { |a, b| (a + (b - a) * k).round }))
    end
  end

  def blend(beat) = smooth((beat - @blend_beat) / 2.0)

  def spot(lane, d, beat)
    x, y, s = Field.point(@mode, lane, d, beat, @slots)
    k = blend(beat)
    if k < 1
      px, py, ps = Field.point(@prev_mode, lane, d, beat, @slots)
      x = px + (x - px) * k
      y = py + (y - py) * k
      s = ps + (s - ps) * k
    end
    roll = Math::PI * 2 * smooth((beat - @roll_beat) / 2.0)
    if roll.positive? && roll < Math::PI * 2
      dx = x - Field::CX
      dy = y - Field::CY
      x = Field::CX + dx * Math.cos(roll) - dy * Math.sin(roll)
      y = Field::CY + dx * Math.sin(roll) + dy * Math.cos(roll)
    end
    [x + @jx, y + @jy, s]
  end

  def spawn_notes(t)
    while @next < @notes.size && (@notes[@next].time - t) * @bps < 5.5
      note = @notes[@next]
      @next += 1
      pool = case note.kind
             when :tap then @gems[note.lane]
             when :bacon then @rashers
             else @mines
             end
      note.sprite = pool.find(&:free?)
      note.sprite&.take
      @live << note
    end
  end

  def sweep(t)
    @live.each do |note|
      late = t - note.time
      if note.kind == :mine
        release(note) if late > 0.12
      elsif !note.judged && late > WINDOWS.last
        miss(note)
      elsif note.missed && late * @bps > 1.2
        release(note)
      end
    end
    @live.reject! { |note| note.sprite.nil? && (note.judged || note.kind == :mine && t - note.time > 0.12) }
  end

  def release(note)
    note.sprite&.release
    note.sprite = nil
    note.judged = true if note.kind == :mine
  end

  def place_field(t, beat)
    @shake *= 0.88
    @shake += 2.5 if @sanity < 25 && !@auto
    @shake = 0.0 if @shake < 0.3
    @jx = (rand - 0.5) * @shake
    @jy = (rand - 0.5) * @shake
    @receptors.each_with_index do |parts, lane|
      x, y, s = spot(lane, 0, beat)
      heat = @heat[lane] *= 0.84
      heat = @heat[lane] = 0.0 if heat < 0.01
      look = [x.round(1), y.round(1), s.round(2), heat.round(2)]
      @spots[lane] = [x, y]
      next if parts[:look] == look

      parts[:look] = look
      parts[:glow].style(left: x, top: y, width: 52 * s, height: 52 * s, fill: lane_rgb(lane, 0.12 + 0.7 * heat))
      parts[:ring].style(left: x, top: y, width: (56 + 10 * heat) * s, height: (56 + 10 * heat) * s)
      parts[:arrow].move(x.round, y.round)
    end
    @live.each do |note|
      next unless note.sprite

      d = (note.time - t) * @bps
      if note.kind == :bacon
        4.times { |lane| note.sprite.place_strip(lane, *spot(lane, d, beat)) }
      else
        note.sprite.place(*spot(note.lane, d, beat))
      end
    end
    phase = beat % 1
    @guides.each_with_index do |dots, lane|
      dots.each_with_index do |dot, j|
        x, y, = spot(lane, j + 1 - phase, beat)
        dot.style(left: x, top: y)
      end
    end
  end

  def autoplay(t)
    @live.each do |note|
      next if note.judged || note.kind == :mine || note.time > t

      judge(note, 0.0)
      @heat[note.lane] = 1.0 if note.lane
    end
  end

  def press(lane)
    t = song_time
    @heat[lane] = 1.0
    note = @live.find { |n| n.kind == :tap && n.lane == lane && !n.judged && (n.time - t).abs <= WINDOWS.last }
    return judge(note, t - note.time) if note

    mine = @live.find { |n| n.kind == :mine && n.lane == lane && !n.judged && (n.time - t).abs <= 0.07 }
    return boom(mine) if mine

    ghost(lane)
  end

  def press_bacon
    t = song_time
    note = @live.find { |n| n.kind == :bacon && !n.judged && (n.time - t).abs <= WINDOWS.last }
    @heat.map! { 0.6 }
    judge(note, t - note.time) if note
  end

  def judge(note, error)
    grade = WINDOWS.index { |window| error.abs <= window }
    note.judged = true
    @counts[grade] += 1
    @errors << error unless @auto
    @combo += 1
    @best_combo = [@best_combo, @combo].max
    @score += (POINTS[grade] * (note.kind == :bacon ? 2 : 1) * (1 + [@combo, 100].min / 50.0)).round
    @sanity = [@sanity + [2.0, 1.2, 0.4][grade], 100].min
    release(note)
    if note.kind == :bacon
      4.times { |lane| burst(lane, grade) }
      pop("BACON!", nil, rgb(255, 143, 127), 44)
      @flash_level = 0.35
      @shake = 12
      shout(%w[bacon chunky! sizzle].sample, "Fred") if rand < 0.5
    else
      burst(note.lane, grade)
      pop(JUDGEMENTS[grade], note.lane, grade == 2 ? rgb(*NIL_RGB) : lane_rgb(note.lane))
    end
    milestone if (@combo % 50).zero?
  end

  def milestone
    @roll_beat = @arr.beat_at(song_time)
    @flash_level = 0.4
    fox_line(:hype)
    shout("chunky bacon!", "Junior")
  end

  def miss(note)
    note.judged = note.missed = true
    note.sprite&.dim
    @counts[3] += 1
    @combo = 0
    @shake = [@shake, 6].max
    pop("nil", note.lane || 1, rgb(*NIL_RGB))
    lose(@level[:drain])
    fox_line(:miss) if now - @last_line_at > 2.5 && rand < 0.4
  end

  def ghost(lane)
    pop("no method", lane, rgb(*NIL_RGB, 0.8), 18)
    lose(@level[:ghost])
    fox_line(:ghost) if now - @last_line_at > 4 && rand < 0.3
  end

  def boom(mine)
    release(mine)
    @mines_hit += 1
    @combo = 0
    @shake = 18
    @flash_level = 0.5
    @flash_red = true
    pop("NoMethodError!", mine.lane, rgb(255, 59, 107))
    lose(10)
    fox_line(:mine)
  end

  def lose(amount)
    return if @auto || @dying

    was = @sanity
    @sanity -= amount
    fox_line(:low) if was >= 25 && @sanity < 25
    return unless @sanity <= 0

    @sanity = 0
    @dying = now + 1.6
    @jukebox.stop
    @count.style(stroke: rgb(255, 59, 107))
    @count.replace("GC.start")
    fox_line(:fail)
    shout("oh no", "Bad News")
  end

  def burst(lane, grade)
    x, y = @spots[lane]
    ring = @bursts.min_by { |b| -b[:age] }
    ring[:age] = 0.0
    ring[:lane] = lane
    ring[:x] = x
    ring[:y] = y
    count = [6, 4, 2][grade]
    @sparks.select { |spark| spark[:life] <= 0 }.first(count).each do |spark|
      angle = rand * Math::PI * 2
      speed = rand(120..260)
      spark.merge!(x: x, y: y, vx: Math.cos(angle) * speed, vy: Math.sin(angle) * speed, life: 1.0, lane: lane)
    end
  end

  def pop(words, lane, color, size = 24)
    x, y = lane ? @spots[lane] : [Field::CX, Field::CY + 40]
    slot = @pops.min_by { |p| p[:life] }
    slot[:life] = 1.0
    slot[:x] = x
    slot[:y] = y - 50
    slot[:color] = color
    slot[:text].style(stroke: color, size: size)
    slot[:text].replace(words)
  end

  def tick_effects(beat)
    dt = 1 / 60.0
    if beat.floor != @last_beat && beat >= 0
      @last_beat = beat.floor
      apply_sky_chaos if @mode == :chaos
      @twinkling&.each { |star| star.style(fill: rgb(255, 255, 255, 0.3)) }
      @twinkling = @stars.sample(4).each { |star| star.style(fill: rgb(255, 255, 255, 0.95)) }
    end
    @bursts.each do |b|
      next if b[:age] >= 1

      b[:age] += dt / 0.3
      size = 54 + 60 * b[:age]
      b[:shape].style(left: b[:x], top: b[:y], width: size, height: size,
        stroke: lane_rgb(b[:lane], [0.9 * (1 - b[:age]), 0].max))
    end
    @sparks.each do |spark|
      next if spark[:life] <= 0

      spark[:life] -= dt / 0.45
      spark[:x] += spark[:vx] * dt
      spark[:y] += spark[:vy] * dt
      spark[:shape].style(left: spark[:x], top: spark[:y], fill: lane_rgb(spark[:lane], [spark[:life], 0].max))
    end
    @pops.each do |p|
      next if p[:life] <= 0

      p[:life] -= dt / 0.6
      p[:text].move((p[:x] - 80).round, (p[:y] - 24 * (1 - p[:life])).round)
      p[:text].replace("") if p[:life] <= 0
    end
    if @flash_level > 0.01
      @flash.show unless @flash_on
      @flash_on = true
      @flash.style(fill: @flash_red ? rgb(255, 40, 80, @flash_level) : rgb(255, 255, 255, @flash_level))
      @flash_level *= 0.86
    elsif @flash_on
      @flash_on = false
      @flash_red = false
      @flash.hide
    end
    @banner.hide if @banner_until && now > @banner_until
    wild = @combo >= 50 ? 1.6 : 1.0
    @run = @mode == :chaos ? (1 - Math.cos(beat * Math::PI / 8)) * 270 : @run.to_f * 0.94
    dance_foxes(beat, @mode == :chaos ? 2.5 : wild, @run)
  end

  def apply_sky_chaos
    paint_sky(*CHAOS_SKIES[@last_beat % CHAOS_SKIES.size])
  end

  def tick_hud(t, beat)
    show(:score, commas(@score)) { |text| @score_text.replace(text) }
    judged = @counts.sum
    accuracy = judged.zero? ? 1.0 : (3 * @counts[0] + 2 * @counts[1] + @counts[2]).fdiv(3 * judged)
    show(:accuracy, format("%.1f%%", accuracy * 100)) { |text| @acc_text.replace(text) }
    show(:combo, @combo) do |combo|
      @combo_text.replace(combo >= 4 ? combo.to_s : "")
      @combo_word.replace(combo >= 4 ? "combo" : "")
      @combo_text.style(stroke: combo >= 50 ? lane_rgb(@last_beat % 4) : INK)
    end
    show(:sanity, @sanity.round) do |sanity|
      @sanity_bar.style(width: [sanity * 2, 6].max, fill: sanity < 25 ? rgb(255, 59, 107) : rgb(*LANE_RGB[3]))
    end
    show(:progress, (W * t / @end_time).clamp(1, W).round) { |width| @progress.style(width: width) }
    if @patch_code && @typed < @patch_code.size
      @typed += 2
      @con_new.replace(@prompt + @patch_code[0, @typed])
      @con_out.replace(@patch_result) if @typed >= @patch_code.size
    end
    count_in(beat) unless @dying
  end

  def count_in(beat)
    word = if beat < 0 then "ready?"
           elsif beat < 3 then (3 - beat.floor).to_s
           elsif beat < 4.6 then "STOMP!"
           else ""
           end
    show(:count, word) do |text|
      @count.style(size: text == "ready?" ? 60 : 120)
      @count.replace(text)
    end
  end

  def show(key, value)
    return if @shown[key] == value

    @shown[key] = value
    yield value
  end

  def pause
    return if @dying

    @paused = true
    @paused_at = song_time
    @jukebox.stop
    @pause_box.show
  end

  def resume
    @paused = false
    @pause_box.hide
    from = [@paused_at - 2 / @bps, 0].max
    @t0 = now - from
    @jukebox.play(@wav, from + offset)
  end

  def nudge(seconds)
    @save["offset"] = (offset + seconds).round(3)
    @t0 += seconds
    save!
    pop("timing #{(offset * 1000).round} ms", 1, rgb(255, 255, 255), 18)
  end

  def key_play(key)
    if @paused
      resume if key == "\n" || key == " "
      quit_play if key == :escape
      return
    end
    return if @dying

    lane = LANE_KEYS[key]
    if lane
      press(lane) unless @auto
      return
    end
    case key
    when " " then press_bacon unless @auto
    when :escape, "p", "P" then pause
    when "[" then nudge(-0.005)
    when "]" then nudge(0.005)
    when "m", "M"
      toggle_sound("m")
      @jukebox.muted ? @jukebox.stop : @jukebox.play(@wav, song_time + offset)
    when "v", "V" then toggle_sound("v")
    end
  end

  def quit_play
    @jukebox.stop
    save!
    go(:title)
  end

  def finish_play(failed: false)
    @jukebox.stop
    total = @chart.scored
    accuracy = (3 * @counts[0] + 2 * @counts[1] + @counts[2]).fdiv(3 * total)
    grade = failed ? ["GC'd", LANE_RGB[0]] : GRADES.find { |floor, _, _| accuracy >= floor }.drop(1)
    @result = {
      song: @arr.song, level: @level, failed: failed, accuracy: accuracy, grade: grade[0], color: grade[1],
      score: @score, counts: @counts.dup, combo: @best_combo, mines: @mines_hit, auto: @auto,
      mode: @mode, section: @arr.sections.index(@section).to_i + 1,
      full: !failed && @counts[3].zero? && @counts.sum == total,
      error: @errors.empty? ? nil : @errors.sum / @errors.size,
    }
    record_best unless failed || @auto
    save!
    go(:results)
  end

  def record_best
    key = "#{@arr.song[:id]}/#{@level[:id]}"
    best = @save["best"][key]
    return if best && best["score"] >= @result[:score]

    @result[:new_best] = true
    @save["best"][key] = { "score" => @result[:score], "accuracy" => @result[:accuracy].round(4), "grade" => @result[:grade] }
  end

  # ------------------------------------------------------------------ results

  def build_results
    r = @result
    scenery
    who = r[:auto] ? "the foxes played" : "you played"
    para "#{who} #{r[:song][:name]} on #{r[:level][:name]}", font: HAND, size: 22, stroke: MUTED,
      align: "center", left: 0, top: 26, width: W, margin: 0
    @grade_shadow = para r[:grade], font: DISPLAY, size: 100, stroke: "#0b0414", align: "center", left: 6, top: 66, width: W, margin: 0
    @grade_text = para r[:grade], font: DISPLAY, size: 100, stroke: rgb(*r[:color]), align: "center", left: 0, top: 60, width: W, margin: 0
    para "#{format("%.2f", r[:accuracy] * 100)}%   ·   #{commas(r[:score])} points", font: DISPLAY, size: 28, stroke: INK,
      align: "center", left: 0, top: 192, width: W, margin: 0
    if r[:full] || r[:new_best]
      badge = [r[:full] && "FULL COMBO", r[:new_best] && "NEW BEST"].compact.join("  ·  ")
      para badge, font: MONO, size: 15, weight: "bold", stroke: rgb(*LANE_RGB[2]), align: "center", left: 0, top: 234, width: W, margin: 0
    end

    r[:failed] ? draw_backtrace(r) : draw_stats(r)

    keys = "ENTER  again     ESC  songs"
    keys += "     O  fix timing" if fixable?
    para keys, font: MONO, size: 14, stroke: INK, align: "right", left: 360, top: 600, width: 576, margin: 0

    fox_corner
    kind = if r[:failed] then :fail
           elsif r[:full] then :full
           else :clear
           end
    fox_line(kind)
    if r[:full] then shout("chunky bacon chunky bacon", "Cellos")
    elsif r[:failed] then shout("segmentation fault. core dumped.", "Zarvox")
    else shout(r[:grade].downcase, "Superstar")
    end
  end

  def draw_stats(r)
    stack left: 300, top: 268, width: 360 do
      background rgb(0, 0, 0, 0.35), curve: 16
      rows = [
        ["CHUNKY!", r[:counts][0], lane_rgb(0)], ["CRISPY", r[:counts][1], lane_rgb(2)], ["raw", r[:counts][2], lane_rgb(1)],
        ["nil", r[:counts][3], rgb(*NIL_RGB)], ["max combo", r[:combo], INK], ["nils stepped on", r[:mines], INK],
      ]
      rows.each_with_index do |(name, value, color), i|
        flow margin: [22, i.zero? ? 16 : 4, 22, 0] do
          para name, font: MONO, size: 15, stroke: color, width: 220, margin: 0
          para value.to_s, font: MONO, size: 15, stroke: INK, align: "right", width: 96, margin: 0
        end
      end
      para timing_words(r), font: MONO, size: 12, stroke: MUTED, margin: [22, 12, 22, 16]
    end
  end

  def draw_backtrace(r)
    c = r[:counts]
    trace = [
      "from feet.rb:#{c[3]}:in 'Feet#stomp'",
      "from monkeypatch.rb:#{r[:section]}:in 'block in Field##{r[:mode]}!'",
      "from foxes.rb:2005:in 'Fox#shout'",
      "from bacon.rb:1:in '<main>'",
    ]
    stack left: 210, top: 246, width: 540 do
      background rgb(0, 0, 0, 0.45), curve: 16
      para "SanityError: sanity exhausted (0 of 100)", font: MONO, size: 15, stroke: lane_rgb(0), margin: [22, 14, 22, 2]
      trace.each { |line| para line, font: MONO, size: 13, stroke: MUTED, margin: [40, 3, 22, 0] }
      para "CHUNKY! #{c[0]} · CRISPY #{c[1]} · raw #{c[2]} · nil #{c[3]}", font: MONO, size: 13, stroke: INK, margin: [22, 12, 22, 14]
    end
  end

  def timing_words(result)
    return "timing: the foxes don't count their own" if result[:auto]
    return "timing: you'd have to hit something first" unless result[:error]

    ms = (result[:error] * 1000).round
    lean = if ms.abs < 8 then "right on it"
           elsif ms.positive? then "late"
           else "early"
           end
    "timing: you hit #{ms.abs} ms #{lean} on average"
  end

  def fixable? = @result[:error] && (@result[:error] * 1000).abs >= 8 && @result[:counts].sum >= 20

  def tick_results
    t = now - @screen_t0
    roll_grid(t)
    wobble = Math.sin(t * 3) * 4
    @grade_text.move(wobble.round, (60 + Math.sin(t * 5) * 3).round)
    @grade_shadow.move((6 + wobble).round, (66 + Math.sin(t * 5) * 3).round)
    dance_foxes(t * 2, @result[:failed] ? 0.2 : 1.2)
  end

  def key_results(key)
    case key
    when "\n", " " then start_song(auto: @result[:auto])
    when :escape then go(:title)
    when "o", "O"
      return unless fixable?

      @save["offset"] = (offset + @result[:error]).round(3)
      save!
      @result[:error] = nil
      fox_line(:title, "ears tuned. timing is now #{(offset * 1000).round} ms.")
    end
  end

  # ------------------------------------------------------------------ calibrate

  def build_calibrate
    scenery
    para "tune the foxes' ears", font: DISPLAY, size: 56, stroke: INK, align: "center", left: 0, top: 40, width: W, margin: 0
    para "tap SPACE on every click you HEAR. don't watch anything. just listen.", font: HAND, size: 20,
      stroke: MUTED, align: "center", left: 0, top: 116, width: W, margin: 0
    nostroke
    rect 180, 250, 600, 4, 2, fill: rgb(255, 255, 255, 0.15)
    rect 478, 226, 4, 52, 2, fill: rgb(*LANE_RGB[3])
    para "early", font: MONO, size: 13, stroke: MUTED, left: 180, top: 284, margin: 0
    para "late", font: MONO, size: 13, stroke: MUTED, align: "right", left: 680, top: 284, width: 100, margin: 0
    @taps = []
    @tap_marks = stack(left: 0, top: 0, width: W, height: 300) {}
    @cal_text = para "", font: MONO, size: 16, stroke: INK, align: "center", left: 0, top: 330, width: W, margin: 0
    @cal_beat = para "", font: DISPLAY, size: 40, stroke: rgb(*LANE_RGB[2]), align: "center", left: 0, top: 170, width: W, margin: 0
    para "SPACE tap   ENTER keep it   [ ] nudge by hand   ESC never mind", font: MONO, size: 13, stroke: INK,
      align: "center", left: 0, top: 380, width: W, margin: 0
    fox_corner
    fox_line(:title, "we'll click. you tap. we do maths.")
    @new_offset = offset
    @click_wav = File.join(CACHE_DIR, "clicks-#{CLICK_BPM}-#{CLICK_BEATS}.wav")
    Chip.click_track(@click_wav, CLICK_BPM, CLICK_BEATS) unless File.exist?(@click_wav)
    @t0 = now + offset
    @jukebox.play(@click_wav)
    calibrate_words
  end

  def calibrate_words
    measured = @taps.size >= 6 ? "measured #{(@new_offset * 1000).round} ms from #{@taps.size} taps" : "#{@taps.size} #{@taps.size == 1 ? "tap" : "taps"} so far"
    @cal_text.replace("timing was #{(offset * 1000).round} ms · #{measured}")
  end

  def tick_calibrate
    beat = song_time * CLICK_BPM / 60.0
    @cal_beat.replace(beat.between?(0, CLICK_BEATS) ? (beat.floor % 4 + 1).to_s : "")
    dance_foxes(beat, 0.6)
    return unless beat > CLICK_BEATS + 1 && !@cal_done

    @cal_done = true
    fox_line(:title, @taps.size >= 6 ? "got it. ENTER to keep it." : "we needed more taps than that. ESC and try again?")
  end

  def key_calibrate(key)
    case key
    when " " then calibration_tap
    when "[" then @new_offset = (@new_offset - 0.005).round(3)
    when "]" then @new_offset = (@new_offset + 0.005).round(3)
    when "\n"
      @save["offset"] = @new_offset
      save!
      @jukebox.stop
      @cal_done = false
      go(:title)
      return
    when :escape
      @jukebox.stop
      @cal_done = false
      go(:title)
      return
    end
    calibrate_words
    @cal_text.replace("timing #{(@new_offset * 1000).round} ms (was #{(offset * 1000).round})") if %w[[ ]].include?(key)
  end

  def calibration_tap
    spacing = 60.0 / CLICK_BPM
    t = song_time
    beat = (t / spacing).round
    return unless beat.between?(2, CLICK_BEATS - 1)

    error = t - beat * spacing
    @taps << error
    sorted = @taps.sort
    @new_offset = (offset + sorted[sorted.size / 2]).round(3)
    x = (480 + error * 2000).clamp(180, 776)
    @tap_marks.append { rect x.round, 236, 4, 32, 2, fill: lane_rgb(@taps.size % 4, 0.8) }
  end

  # ------------------------------------------------------------------ start

  @clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  @arrangements = {}
  @song_index = 0
  @level_index = 1
  @spots = Array.new(4) { [0, 0] }
  load_save
  @jukebox = Jukebox.new
  @jukebox.muted = @save["muted"]
  @voices = Voices.new
  @voices.quiet = !@save["voices"]

  @stage = stack(left: 0, top: 0, width: W, height: H) {}
  keypress { |key| send("key_#{@screen}", key) }
  animate(60) { send("tick_#{@screen}") }
  go(:title)
end
