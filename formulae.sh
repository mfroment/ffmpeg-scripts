# Create a mirror
ffmpeg -i input.mp4 -vf hflip mirror.mp4

# Create a mosaic with the mirror in the top left corner, the original in the bottom right corner, and 1:2 scaling
ffmpeg -i input.mp4 -i mirror.mp4 -filter_complex \
"[0:v]scale=iw*2:ih*2[b];[b]pad=w=iw:h=ih*3/2:x=0:y=ih*1/2[base]; \
 [1:v]scale=iw:ih[s];[s]pad=w=iw:h=ih*3:x=0:y=0[small]; \
 [small][base]hstack=inputs=2" \
-map 0:a -c:a copy output.mp4
