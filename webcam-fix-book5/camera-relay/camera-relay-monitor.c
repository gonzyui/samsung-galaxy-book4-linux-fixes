/*
 * camera-relay-monitor — Lightweight v4l2loopback client event monitor
 *
 * Opens the v4l2loopback device for writing and writes black frames to
 * keep ready_for_capture=1 (required for capture clients to STREAMON).
 * Monitors for client connections and prints "START" when a capture
 * client connects, "STOP" when the last client disconnects.
 *
 * When emitting START, the monitor CLOSES its writer fd so the GStreamer
 * pipeline can open the device for output (v4l2loopback allows only one
 * writer). During pipeline activity, client detection switches from
 * v4l2 events to /proc polling. After STOP, the monitor reopens the
 * device and resumes black frame writing.
 *
 * Build:  gcc -O2 -Wall -o camera-relay-monitor camera-relay-monitor.c
 * Usage:  camera-relay-monitor /dev/video0 [width height]
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

/* Event IDs for v4l2loopback versions */
#define V4L2_EVENT_CLIENT_USAGE_OLD  (V4L2_EVENT_PRIVATE_START)
#define V4L2_EVENT_CLIENT_USAGE_NEW  (V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1)

static volatile sig_atomic_t running = 1;

static void handle_signal(int sig)
{
	(void)sig;
	running = 0;
}

static int xioctl(int fd, unsigned long request, void *arg)
{
	int r;
	do {
		r = ioctl(fd, request, arg);
	} while (r == -1 && errno == EINTR);
	return r;
}

/* Count processes (other than ours) that have this device open */
static int count_other_openers(dev_t dev_id, pid_t our_pid)
{
	DIR *proc_dir;
	struct dirent *proc_entry;
	int count = 0;

	proc_dir = opendir("/proc");
	if (!proc_dir)
		return 0;

	while ((proc_entry = readdir(proc_dir)) != NULL) {
		char *endp;
		long pid = strtol(proc_entry->d_name, &endp, 10);
		if (*endp != '\0' || pid <= 0)
			continue;
		if ((pid_t)pid == our_pid)
			continue;

		char fd_dir_path[128];
		snprintf(fd_dir_path, sizeof(fd_dir_path),
			 "/proc/%ld/fd", pid);

		DIR *fd_dir = opendir(fd_dir_path);
		if (!fd_dir)
			continue;

		struct dirent *fd_entry;
		int found = 0;
		while ((fd_entry = readdir(fd_dir)) != NULL) {
			char link_path[384];
			struct stat st;

			snprintf(link_path, sizeof(link_path),
				 "%s/%s", fd_dir_path, fd_entry->d_name);

			if (stat(link_path, &st) == 0 &&
			    S_ISCHR(st.st_mode) &&
			    st.st_rdev == dev_id) {
				found = 1;
				break;
			}
		}
		closedir(fd_dir);
		if (found)
			count++;
	}
	closedir(proc_dir);
	return count;
}

/* Open device for writing, set format, write initial black frame.
 * Returns fd on success, -1 on failure. */
static int open_writer(const char *device, int width, int height,
		       int frame_size, const char *black_frame)
{
	int fd = open(device, O_WRONLY);
	if (fd < 0) {
		fprintf(stderr, "[monitor] Cannot open %s: %s\n",
			device, strerror(errno));
		return -1;
	}

	struct v4l2_format fmt;
	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
	fmt.fmt.pix.width = width;
	fmt.fmt.pix.height = height;
	fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
	fmt.fmt.pix.sizeimage = frame_size;
	fmt.fmt.pix.field = V4L2_FIELD_NONE;

	if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0)
		fprintf(stderr, "[monitor] S_FMT warning: %s\n",
			strerror(errno));

	if (write(fd, black_frame, frame_size) != frame_size)
		fprintf(stderr, "[monitor] Initial write warning: %s\n",
			strerror(errno));

	return fd;
}

/* Try to subscribe to v4l2loopback client events.
 * Returns the event type on success, 0 on failure. */
static __u32 try_subscribe_events(int fd)
{
	struct v4l2_event_subscription sub;

	memset(&sub, 0, sizeof(sub));
	sub.type = V4L2_EVENT_CLIENT_USAGE_OLD;
	sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
	if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) == 0) {
		fprintf(stderr,
			"[monitor] Using v4l2loopback 0.12.x event API\n");
		return V4L2_EVENT_CLIENT_USAGE_OLD;
	}

	memset(&sub, 0, sizeof(sub));
	sub.type = V4L2_EVENT_CLIENT_USAGE_NEW;
	sub.flags = V4L2_EVENT_SUB_FL_SEND_INITIAL;
	if (xioctl(fd, VIDIOC_SUBSCRIBE_EVENT, &sub) == 0) {
		fprintf(stderr,
			"[monitor] Using v4l2loopback 0.13+ event API\n");
		return V4L2_EVENT_CLIENT_USAGE_NEW;
	}

	return 0;
}

int main(int argc, char *argv[])
{
	const char *device;
	int width = 1920, height = 1080;
	int frame_size;

	if (argc < 2 || argc > 4) {
		fprintf(stderr, "Usage: %s <device> [width height]\n",
			argv[0]);
		return 1;
	}

	device = argv[1];
	if (argc >= 3)
		width = atoi(argv[2]);
	if (argc >= 4)
		height = atoi(argv[3]);

	frame_size = width * height * 2;  /* YUY2: 2 bytes/pixel */

	setvbuf(stdout, NULL, _IOLBF, 0);

	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);

	/* Allocate YUY2 black frame (BT.601: Y=0x10, U=V=0x80) */
	char *black_frame = malloc(frame_size);
	if (!black_frame) {
		fprintf(stderr, "ERROR: Cannot allocate frame buffer\n");
		return 1;
	}
	for (int i = 0; i < frame_size; i += 4) {
		black_frame[i + 0] = 0x10;
		black_frame[i + 1] = 0x80;
		black_frame[i + 2] = 0x10;
		black_frame[i + 3] = 0x80;
	}

	/* Get device stat for /proc polling */
	struct stat dev_stat;
	if (stat(device, &dev_stat) < 0) {
		fprintf(stderr, "ERROR: Cannot stat %s: %s\n",
			device, strerror(errno));
		free(black_frame);
		return 1;
	}
	pid_t our_pid = getpid();

	/* Open writer and set up device */
	int fd = open_writer(device, width, height, frame_size, black_frame);
	if (fd < 0) {
		free(black_frame);
		return 1;
	}

	/* Try event-based client detection */
	__u32 event_type = try_subscribe_events(fd);
	int use_events = (event_type != 0);

	if (!use_events)
		fprintf(stderr, "[monitor] No event support, using /proc polling\n");

	fprintf(stderr, "[monitor] Watching %s (%dx%d)\n",
		device, width, height);
	printf("READY\n");

	/*
	 * Main loop: alternate between IDLE and PIPELINE_ACTIVE states.
	 *
	 * IDLE: monitor holds writer fd, writes black frames, watches
	 *       for client connections via events or /proc polling.
	 *
	 * PIPELINE_ACTIVE: monitor has CLOSED writer fd (so the GStreamer
	 *       pipeline can open it). Uses /proc polling to detect when
	 *       all clients have disconnected.
	 */
	int pipeline_active = 0;
	int prev_clients = 0;

	if (use_events) {
		/* Drain initial event */
		struct v4l2_event ev;
		memset(&ev, 0, sizeof(ev));
		xioctl(fd, VIDIOC_DQEVENT, &ev);
	}

	while (running) {
		if (!pipeline_active) {
			/*
			 * IDLE state: writer fd is open.
			 * Write black frames to maintain ready_for_capture.
			 * Watch for client connections.
			 */
			(void)!write(fd, black_frame, frame_size);

			int client_detected = 0;

			if (use_events) {
				struct pollfd pfd = {
					.fd = fd, .events = POLLPRI
				};
				int ret = poll(&pfd, 1, 1000);
				if (ret < 0 && errno != EINTR)
					break;

				if (ret > 0 && (pfd.revents & POLLPRI)) {
					struct v4l2_event ev;
					memset(&ev, 0, sizeof(ev));
					if (xioctl(fd, VIDIOC_DQEVENT,
						   &ev) == 0 &&
					    ev.type == event_type) {
						__u32 count;
						memcpy(&count, &ev.u,
						       sizeof(count));
						if (event_type ==
						    V4L2_EVENT_CLIENT_USAGE_OLD)
							client_detected =
								(count > 0);
						else
							client_detected =
								(count == 0);
					}
				}
			} else {
				/* /proc polling fallback */
				int clients = count_other_openers(
					dev_stat.st_rdev, our_pid);
				if (clients > 0 && prev_clients == 0)
					client_detected = 1;
				prev_clients = clients;
				if (!client_detected)
					usleep(500000);
			}

			if (client_detected) {
				fprintf(stderr,
					"[monitor] Client connected — "
					"yielding writer fd\n");
				close(fd);
				fd = -1;
				pipeline_active = 1;
				prev_clients = 0;
				printf("START\n");
				/*
				 * Give the pipeline time to open the
				 * device before we start polling.
				 */
				sleep(3);
			}
		} else {
			/*
			 * PIPELINE_ACTIVE state: writer fd is closed.
			 * The GStreamer pipeline has the device open for
			 * writing. Use /proc polling to detect when all
			 * capture clients have disconnected.
			 *
			 * Openers: pipeline (1 writer) + clients (readers).
			 * When count drops to <=1 (just pipeline or empty),
			 * clients are gone. Track how long we've been at
			 * <=1 openers to avoid false positives during
			 * pipeline startup or brief client transitions.
			 */
			static int idle_ticks = 0;
			static int peak_openers = 0;

			int openers = count_other_openers(
				dev_stat.st_rdev, our_pid);

			if (openers > peak_openers)
				peak_openers = openers;

			if (openers <= 1) {
				idle_ticks++;
			} else {
				idle_ticks = 0;
			}

			/*
			 * Emit STOP when:
			 * - We've seen clients (peak > 1) and now they're
			 *   gone (<=1 for 3+ ticks = ~3 seconds), OR
			 * - No clients ever appeared after 30 seconds
			 *   (pipeline started but nobody reconnected)
			 */
			int clients_left = (peak_openers > 1 &&
					    idle_ticks >= 3);
			int nobody_came = (peak_openers <= 1 &&
					   idle_ticks >= 30);

			if (clients_left || nobody_came) {
				fprintf(stderr,
					"[monitor] All clients disconnected"
					" (openers=%d, peak=%d)\n",
					openers, peak_openers);
				printf("STOP\n");
				pipeline_active = 0;
				prev_clients = 0;
				idle_ticks = 0;
				peak_openers = 0;

				/*
				 * Wait for the bash script to stop the
				 * pipeline, then reclaim the writer fd.
				 */
				sleep(3);
				fd = open_writer(device, width, height,
						 frame_size, black_frame);
				if (fd < 0) {
					fprintf(stderr,
						"[monitor] Failed to "
						"reopen writer\n");
					break;
				}

				/* Re-subscribe to events if available */
				if (use_events) {
					event_type =
						try_subscribe_events(fd);
					if (event_type == 0)
						use_events = 0;
					else {
						struct v4l2_event ev;
						memset(&ev, 0, sizeof(ev));
						xioctl(fd, VIDIOC_DQEVENT,
						       &ev);
					}
				}

				fprintf(stderr,
					"[monitor] Writer fd reclaimed,"
					" resuming idle\n");
			}
			prev_clients = openers;

			/* Poll interval */
			for (int i = 0; i < 10 && running; i++)
				usleep(100000);
		}
	}

	fprintf(stderr, "[monitor] Shutting down\n");
	free(black_frame);
	if (fd >= 0)
		close(fd);
	return 0;
}
