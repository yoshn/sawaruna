#!/bin/sh
# Cross-compile Sawaruna for Windows (x64) with MinGW-w64
set -e
cd "$(dirname "$0")"
x86_64-w64-mingw32-windres sawaruna.rc -O coff -o res.o
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -municode -mwindows -static \
  sawaruna.c res.o -o Sawaruna.exe -lwtsapi32 -lshell32 -luser32 -ladvapi32
rm -f res.o
x86_64-w64-mingw32-strip Sawaruna.exe
