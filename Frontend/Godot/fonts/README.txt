Fonts. If these files exist they are used, otherwise Godot's built-in font:
  fonts/title.ttf  - screen titles (Nunito, SIL OFL: title-OFL.txt), drawn at weight 900 with
                     the orange-to-red gradient, dark edge and light rim (look/menu_look.tres,
                     group "Title"; the gradient is look/title_gradient.gdshader)
  fonts/menu.ttf   - lobby headings and names (e.g. Lilita One, SIL OFL)
  fonts/body.ttf   - descriptions and forms   (e.g. Chakra Petch, SIL OFL)
(.otf / .woff2 also work: menu.otf, body.woff2 ...)
The look's own fonts (Inspector: title_font, menu_font, button_font, body_font) win over these.
