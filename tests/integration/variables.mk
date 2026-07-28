CC = gcc
CFLAGS = -O2 -Wall
TARGET = myapp
OBJS = main.o util.o

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^
main.o: main.c
	$(CC) $(CFLAGS) -c $<
util.o: util.c
	$(CC) $(CFLAGS) -c $<
clean: ; rm -f $(TARGET) $(OBJS)
