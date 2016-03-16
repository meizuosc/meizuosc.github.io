#!/usr/bin/env python

from PIL import Image

bg_sidebar = Image.open("bg_sidebar.png")
bg_sidebar_active = Image.open("bg_sidebar_active.png")
bg_main = Image.open("bg_main.png")
bg_list_style = Image.open("bg_list_style.png")

horizontal_padding = 5
vertical_padding = 15

height = bg_list_style.size[1] + bg_sidebar.size[1] + bg_sidebar_active.size[1] + vertical_padding * 2
width = bg_sidebar.size[0] * 2 + horizontal_padding

image = Image.new('RGBA', (width, height))

bg_list_style_offset = (0, 0)
image.paste(bg_list_style, bg_list_style_offset)
print 'bg_list_style     -> background-position: -{}px -{}px'.format(*bg_list_style_offset)

bg_sidebar_active_offset = (0, bg_list_style.size[1] + vertical_padding)
image.paste(bg_sidebar_active, bg_sidebar_active_offset)
print 'bg_sidebar_active -> background-position: -{}px -{}px'.format(*bg_sidebar_active_offset)

bg_sidebar_offset = (0, bg_list_style.size[1] + bg_sidebar_active.size[1] + vertical_padding * 2)
image.paste(bg_sidebar, bg_sidebar_offset)
print 'bg_sidebar        -> background-position: -{}px -{}px'.format(*bg_sidebar_offset)

total_height = 0
while total_height < height:
    image.paste(bg_main, (width - bg_main.size[0], total_height))
    total_height += bg_main.size[1]
bg_main_offset = (bg_sidebar.size[0] + horizontal_padding, 0)
print 'bg_main           -> background-position: -{}px -{}px'.format(*bg_main_offset)

image.save('bg_all.png', 'PNG')
