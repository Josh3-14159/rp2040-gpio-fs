CC      = gcc
CFLAGS  = -Wall -Wextra -O2 $(shell pkg-config fuse3 --cflags)
LDFLAGS = $(shell pkg-config fuse3 --libs) -lpthread
TARGET  = rp2040fs

all: $(TARGET)

$(TARGET): rp2040fs.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
