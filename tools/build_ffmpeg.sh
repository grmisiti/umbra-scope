#!/bin/zsh
# Builds the FFmpeg the app ships: LGPL 2.1+ (no --enable-gpl), decoders and demuxers only, no network, shared
# libraries with @rpath install names, for macOS 14 on Apple Silicon. Output: third_party/ffmpeg-build.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION=n8.1.3
[[ -d third_party/ffmpeg-src ]] || git clone -q --depth 1 --branch $VERSION https://github.com/FFmpeg/FFmpeg.git third_party/ffmpeg-src
cd third_party/ffmpeg-src
DEC=h264,hevc,prores,prores_raw,dnxhd,mpeg2video,mpeg4,mjpeg,dvvideo,vp8,vp9,av1,ffv1,cfhd,jpeg2000,v210,v410,rawvideo,qtrle,png,tiff,dpx,exr
./configure --prefix=/umbra-ffmpeg --enable-shared --disable-static --disable-programs --disable-doc \
  --disable-network --disable-avdevice --disable-avfilter --disable-swresample --disable-everything --disable-autodetect \
  --enable-zlib --enable-protocol=file --enable-demuxer=mov,mxf,matroska,avi,mpegts,mpegps,dv,h264,hevc \
  --enable-decoder=$DEC --enable-parser=h264,hevc,mpeg4video,mpegvideo,vp8,vp9,mjpeg,dnxhd,av1,png \
  --enable-bsf=vp9_superframe_split --arch=arm64 --cc=clang \
  --extra-cflags="-mmacosx-version-min=14.0" \
  --extra-ldflags="-mmacosx-version-min=14.0" --install-name-dir=@rpath
make -j10
# The prefix is a neutral path: FFmpeg records its configure line in the libraries, and a real path would leak the
# builder's home folder. Install into a staging dir and copy it to where build.sh looks.
make install DESTDIR=$ROOT/third_party/ffmpeg-stage
mkdir -p $ROOT/third_party/ffmpeg-build
cp -R $ROOT/third_party/ffmpeg-stage/umbra-ffmpeg/. $ROOT/third_party/ffmpeg-build/
