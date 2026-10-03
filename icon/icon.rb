# The Dance Dance Monkeypatch icon: the fox in the top hat, in the middle of the round field,
# with an arrow coming in from every side.
#
# The window is the 1024 px icon canvas, with the tile on macOS's icon grid (824 px, 100 in
# from each edge). A frame is always opaque, so the corners are cut away afterwards:
#
#   ./scarpe.sh peek icon/icon.rb --shot icon/square.png
#   magick icon/square.png \( -size 1024x1024 xc:none -fill white \
#     -draw "roundrectangle 100,100 923,923 185,185" \) -compose DstIn -composite icon/icon.png

FUR = "#f26a1b"
CREAM = "#fff1dc"
DARK = "#24112f"
LANES = [[255, 59, 107], [45, 226, 230], [255, 210, 63], [138, 255, 92]]
ARROW = [[-11, 0], [1, -10], [1, -4], [11, -4], [11, 4], [1, 4], [1, 10]]
K = 5.4 # the game draws its fox's head about 80 px wide; here it is about 430

Shoes.app(title: "Dance Dance Monkeypatch icon", width: 1024, height: 1024, resizable: false) do
  def pt(x, y)
    [@x + x * K, @y + y * K]
  end

  def poly(points, color)
    nostroke
    fill color
    shape do
      move_to(*pt(*points[0]))
      points.drop(1).each { |p| line_to(*pt(*p)) }
      line_to(*pt(*points[0]))
    end
  end

  def blob(x, y, w, h, color)
    nostroke
    fill color
    oval(*pt(x, y), w * K, h * K)
  end

  # An arrow gem, `lane` turning the left-pointing arrow to face its way.
  def candy(cx, cy, lane)
    r, g, b = LANES[lane]
    nostroke
    fill rgb(r, g, b, 0.18)
    oval cx, cy, 190, center: true
    stroke rgb(255, 255, 255, 0.9)
    strokewidth 10
    fill rgb(r, g, b)
    oval cx, cy, 140, center: true
    nostroke
    fill rgb(255, 255, 255, 0.7)
    oval cx - 26, cy - 28, 38, center: true
    fill DARK
    points = ARROW.map do |x, y|
      case lane
      when 0 then [x, y]
      when 1 then [y, -x]
      when 2 then [y, x]
      else [-x, y]
      end
    end
    shape do
      move_to cx + points[0][0] * 3.6, cy + points[0][1] * 3.6
      points.drop(1).each { |x, y| line_to cx + x * 3.6, cy + y * 3.6 }
      line_to cx + points[0][0] * 3.6, cy + points[0][1] * 3.6
    end
  end

  background ENV["ICON_MATTE"] || "white"
  stack(left: 100, top: 100, width: 824, height: 824) do
    background "#3a1257".."#120624"
    nostroke
    15.times do |i|
      stroke rgb(255, 110, 199, 0.18)
      strokewidth 3
      line 412 + (i - 7) * 20, 560, 412 + (i - 7) * 150, 824
    end
    7.times { |k| rect 0, 560 + 264 * ((k + 0.5) / 7.0)**2, 824, 3, fill: rgb(255, 110, 199, 0.2) }
  end

  nofill
  stroke rgb(255, 255, 255, 0.16)
  strokewidth 6
  oval 512, 512, 660, center: true
  [[182, 512, 0], [512, 842, 1], [512, 182, 2], [842, 512, 3]].each { |x, y, lane| candy(x, y, lane) }

  @x = 512 - 56 * K
  @y = 548 - 50 * K
  poly([[20, 46], [30, 2], [52, 30]], FUR)
  poly([[60, 30], [82, 2], [92, 46]], FUR)
  blob(16, 24, 80, 62, FUR)
  poly([[28, 34], [32, 12], [44, 30]], "#a8400e")
  poly([[68, 30], [80, 12], [84, 34]], "#a8400e")
  blob(30, 54, 52, 32, CREAM)
  blob(37, 45, 10, 12, DARK)
  blob(65, 45, 10, 12, DARK)
  blob(39, 47, 4, 4, "#ffffff")
  blob(67, 47, 4, 4, "#ffffff")
  blob(51, 60, 10, 7, DARK)
  blob(49, 69, 14, 11, "#7a1d2e")
  nostroke
  fill DARK
  rect(*pt(36, 0), 40 * K, 24 * K, 3 * K)
  fill "#ff3b6b"
  rect(*pt(36, 14), 40 * K, 5 * K)
  fill DARK
  rect(*pt(26, 21), 60 * K, 6 * K, 3 * K)
end
