@echo off
setlocal

set SOURCE=src
set OUTPUT=riscbox.exe

set MODE=dev
if "%1%"=="d" set MODE=debug
if "%1%"=="r" set MODE=release

set TARGET=windows_amd64
if "%1%"=="-target" (
  set TARGET=%2%
)
if "%2%"=="-target" (
  set TARGET=%3%
)

if "%MODE%"=="dev"     set FLAGS=-o:none -use-separate-modules
if "%MODE%"=="debug"   set FLAGS=-o:none -debug
if "%MODE%"=="release" set FLAGS=-o:speed -vet -no-bounds-check -no-type-assert

echo [package:%SOURCE%]
echo [target:%TARGET%]
echo [mode:%MODE%]

if not exist out mkdir out
odin build %SOURCE% -out:out/%OUTPUT% -target:%TARGET% %FLAGS%
