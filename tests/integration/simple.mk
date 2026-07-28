CC = gcc
CFLAGS = -Wall
all: hello

hello: hello.o
hello.o: hello.c
