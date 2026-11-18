use std::{
    future::{Future as _, Ready, ready},
    io,
    pin::Pin,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::TcpStream,
    time::Sleep,
};

#[derive(Clone)]
pub struct WriteIdleTimeout;

impl<S> axum_server::accept::Accept<TcpStream, S> for WriteIdleTimeout {
    type Stream = HostSocket;
    type Service = S;
    type Future = Ready<io::Result<(HostSocket, S)>>;
    fn accept(&self, socket: TcpStream, service: S) -> Self::Future {
        ready(Ok((
            HostSocket {
                socket,
                deadline: None,
            },
            service,
        )))
    }
}

pub struct HostSocket {
    socket: TcpStream,
    deadline: Option<Pin<Box<Sleep>>>,
}

impl AsyncRead for HostSocket {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_read(cx, buf)
    }
}

impl AsyncWrite for HostSocket {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match Pin::new(&mut self.socket).poll_write(cx, buf) {
            Poll::Ready(result) => {
                self.deadline = None;
                Poll::Ready(result)
            }
            Poll::Pending => {
                // A blocked socket can stop Hyper from polling the body, so time writes here.
                let timer = self
                    .deadline
                    .get_or_insert_with(|| Box::pin(tokio::time::sleep(Duration::from_secs(120))));
                if timer.as_mut().poll(cx).is_ready() {
                    Poll::Ready(Err(io::ErrorKind::TimedOut.into()))
                } else {
                    Poll::Pending
                }
            }
        }
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.socket).poll_shutdown(cx)
    }
}
