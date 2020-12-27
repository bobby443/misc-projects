#!/usr/bin/perl

# Basic info:
# 
# Script when run creates a unix socket in the home folder. Other applications can then send a message containing the quality setting, seek time, and path of the file. The server then makes a pipe that ffmpeg writes to and the client can read. Server handles clean up from timeouts. 

use strict;
use warnings;
use feature qw(say);
use IO::Socket::UNIX qw( SOCK_STREAM SOMAXCONN);
use IO::Select;



{
	package transConnection;
	use POSIX qw(mkfifo :sys_wait_h);

	sub new{
		my $class = shift;

		my $self = {
			conn => shift,
			state => 0,
			child => 0,
			creation => time(),
			timeout => shift,
			buff => "",
			cmd => [],
			ppath => "",
			cmdgen => shift
		};
		$self->{conn}->blocking(0);
		bless $self, $class;
		return $self;
	}
	
	sub kill{
		(my $self) = @_;

		$self->{conn}->shutdown(2);
		close($self->{conn});

	       	if($self->{child} > 0){
			kill('KILL', $self->{child});
			#say("killed: " . $self->{child});
			waitpid($self->{child}, 0);
		}	
		$self->{child} = 0;
		if(-e $self->{ppath}){
			unlink($self->{ppath});
		}
	}

	sub yield{
		(my $self) = @_;
		my $s = $self->{state};
		if($s == 0){
			return $self->_setup();
		}elsif($s == 1){
			return $self->_checkConn();
		}else{
			return 0; #obj is dead
		}
	}


	sub _setup{
		my ($self) = @_;
		if((time() - $self->{creation}) > $self->{timeout}){
			$self->{state} = 99;
			return 0;
		}

		if(length($self->{buff}) > 100){
			say "command too long";
			$self->{state} = 99;
			return 0;
		}

		if($self->{buff} !~ /(.*);/){
			return 1;
		}

		my $op = $1;
		$self->{ppath} = "/tmp/" . time() . ".vpipe";
		my $cmd = $self->{cmdgen}->($op);
		if(not defined $cmd){
			#say "Invalid ffmpeg cmd";
			$self->{state} = 99;
			return 0;
		}

		
		#start the fork
		if(-e $self->{ppath}){
			$self->{state} = 99;
			return 0;
		}
		mkfifo($self->{ppath}, 0700) or return 0;
		$self->{conn}->send($self->{ppath} ."\n");
	
		$self->{child} = fork();
		((say "could not fork") and return 0) if not defined $self->{child};

		if($self->{child} == 0){
			#child
			open STDOUT, '>', "/dev/null";
			open STDERR, ">", "/dev/null";
			$SIG{INT} = $SIG{TERM} = sub {return 0;};
			my @args = @{$cmd};
			push @args, $self->{ppath};
			exec "ffmpeg", @args or ((say "couldn't exec ffmpeg: $!") and (return -1));
			exit 0; #should never be reached
		}
		
		$self->{state} = 1;
		return 1;
	}

	
	sub _checkConn{
		my ($self) = @_;
	
		if($self->{connDrop}){
			return 0;
		}

		if(waitpid($self->{child}, WNOHANG) == 0){
			return 1;
		}
		$self->{child} = 0;

		return 0;
	}

	sub read_event{
		my ($self) = @_;	
		my $buff = "";
		my $s = read($self->{conn}, $buff, 100);	
		if(not defined $s){
			$s = 0;
		}
		
		if($s == 0){
			$self->{conn}->shutdown(2);
			$self->{connDrop} = 1;
			#say "connection dropped";
			return 0;
		}
		$self->{buff} .= $buff;
		return 1;
	}

	use overload "*{}" => sub {my ($self) = @_; return \*{$self->{conn}}}, fallback=>1;
}




sub ffmpegCommandGen{
	my $cmd = shift @_;
	my $op;
	my $path;
	my $time;

	if($cmd =~ /^(\w+) (\d\d:\d\d:\d\d) ([\w\/\. ]+)$/){
		$op = $1;
		$time = $2;
		$path = $3;
	}else{
		return undef;
	}
	#add in restrictions to path later
	$path =~ s/\.\.//;
	if(not (-e $path)){
		return undef;
	}


	if($op eq "HIGH"){
		#return ["-ss", $time, "-i", $path, "-c:v", "mpeg2video", "-qscale", "2", "-c:a", "mp2", "-b:a", "192K", "-y", "-f", "mpegts"];
		return ["-ss", $time, "-i", $path, "-c:v", "libx264", "-preset", "veryfast", "-crf","24","-c:a", "aac", "-b:a", "192K", "-y", "-f", "mpegts"];
	}
	return undef;
}

my $SOCK_PATH = "$ENV{HOME}/transd.sock";
unlink $SOCK_PATH;

print $SOCK_PATH . "\n";
my $server = IO::Socket::UNIX->new(
	Type => SOCK_STREAM,
	Local => $SOCK_PATH,
	Listen => SOMAXCONN	
);


my $sel = IO::Select->new($server);

$SIG{TERM} = sub{
	foreach($sel->handles()){
		if($_ != $server){
			$_->kill();
		}
	}
	exit;
};

$SIG{INT} = $SIG{TERM};

while(1){
	my @ready = $sel->can_read(0.01);
	foreach my $fh (@ready){
		if($fh == $server){
			my $nfh = $server->accept();
			#say fileno($nfh);
			$sel->add(transConnection->new($nfh, 5, \&ffmpegCommandGen));
		}else{
			if(not $fh->read_event()){
				$fh->kill();
				$sel->remove($fh);
			}
		}
	}
	foreach my $fh ($sel->handles()){
		if($fh != $server){
			if(not $fh->yield()){	
				$fh->kill();
				$sel->remove($fh);
			}
		}
	}
}

