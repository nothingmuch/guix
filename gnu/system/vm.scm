;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2013 Ludovic Courtès <ludo@gnu.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu system vm)
  #:use-module (guix config)
  #:use-module (guix store)
  #:use-module (guix derivations)
  #:use-module (guix packages)
  #:use-module (guix monads)
  #:use-module ((gnu packages base)
                #:select (%final-inputs
                          guile-final gcc-final glibc-final
                          coreutils findutils grep sed))
  #:use-module (gnu packages guile)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages qemu)
  #:use-module (gnu packages parted)
  #:use-module (gnu packages zile)
  #:use-module (gnu packages grub)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages linux-initrd)
  #:use-module (gnu packages package-management)
  #:use-module ((gnu packages make-bootstrap)
                #:select (%guile-static-stripped))
  #:use-module (gnu packages system)

  #:use-module (gnu system shadow)
  #:use-module (gnu system linux)
  #:use-module (gnu system grub)
  #:use-module (gnu system dmd)

  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:use-module (ice-9 match)

  #:export (expression->derivation-in-linux-vm
            qemu-image
            system-qemu-image))


;;; Commentary:
;;;
;;; Tools to evaluate build expressions within virtual machines.
;;;
;;; Code:

(define (lower-inputs inputs)
  "Turn any package from INPUTS into a derivation; return the corresponding
input list as a monadic value."
  (with-monad %store-monad
    (sequence %store-monad
              (map (match-lambda
                    ((name (? package? package) sub-drv ...)
                     (mlet %store-monad ((drv (package->derivation package)))
                       (return `(,name ,drv ,@sub-drv))))
                    ((name (? string? file))
                     (return `(,name ,file)))
                    (tuple
                     (return tuple)))
                   inputs))))

(define* (expression->derivation-in-linux-vm name exp
                                             #:key
                                             (system (%current-system))
                                             (inputs '())
                                             (linux linux-libre)
                                             (initrd qemu-initrd)
                                             (qemu qemu/smb-shares)
                                             (env-vars '())
                                             (modules '())
                                             (guile-for-build
                                              (%guile-for-build))

                                             (make-disk-image? #f)
                                             (references-graphs #f)
                                             (disk-image-size
                                              (* 100 (expt 2 20))))
  "Evaluate EXP in a QEMU virtual machine running LINUX with INITRD.  In the
virtual machine, EXP has access to all of INPUTS from the store; it should put
its output files in the `/xchg' directory, which is copied to the derivation's
output when the VM terminates.

When MAKE-DISK-IMAGE? is true, then create a QEMU disk image of
DISK-IMAGE-SIZE bytes and return it.

When REFERENCES-GRAPHS is true, it must be a list of file name/store path
pairs, as for `derivation'.  The files containing the reference graphs are
made available under the /xchg CIFS share."
  ;; FIXME: Allow use of macros from other modules, as done in
  ;; `build-expression->derivation'.

  (define input-alist
    (with-monad %store-monad
      (map (match-lambda
            ((input (? package? package))
             (mlet %store-monad ((out (package-file package #:system system)))
               (return `(,input . ,out))))
            ((input (? package? package) sub-drv)
             (mlet %store-monad ((out (package-file package
                                                    #:output sub-drv
                                                    #:system system)))
               (return `(,input . ,out))))
            ((input (? derivation? drv))
             (return `(,input . ,(derivation->output-path drv))))
            ((input (? derivation? drv) sub-drv)
             (return `(,input . ,(derivation->output-path drv sub-drv))))
            ((input (and (? string?) (? store-path?) file))
             (return `(,input . ,file))))
           inputs)))

  (define builder
    ;; Code that launches the VM that evaluates EXP.
    `(let ()
       (use-modules (guix build utils)
                    (srfi srfi-1)
                    (ice-9 rdelim))

       (let ((out     (assoc-ref %outputs "out"))
             (cu      (string-append (assoc-ref %build-inputs "coreutils")
                                     "/bin"))
             (qemu    (string-append (assoc-ref %build-inputs "qemu")
                                     "/bin/qemu-system-"
                                     (car (string-split ,system #\-))))
             (img     (string-append (assoc-ref %build-inputs "qemu")
                                     "/bin/qemu-img"))
             (linux   (string-append (assoc-ref %build-inputs "linux")
                                     "/bzImage"))
             (initrd  (string-append (assoc-ref %build-inputs "initrd")
                                     "/initrd"))
             (builder (assoc-ref %build-inputs "builder")))

         ;; XXX: QEMU uses "rm -rf" when it's done to remove the temporary SMB
         ;; directory, so it really needs `rm' in $PATH.
         (setenv "PATH" cu)

         ,(if make-disk-image?
              `(zero? (system* img "create" "-f" "qcow2" "image.qcow2"
                               ,(number->string disk-image-size)))
              '(begin))

         (mkdir "xchg")

         ;; Copy the reference-graph files under xchg/ so EXP can access it.
         (begin
           ,@(match references-graphs
               (((graph-files . _) ...)
                (map (lambda (file)
                       `(copy-file ,file
                                   ,(string-append "xchg/" file)))
                     graph-files))
               (#f '())))

         (and (zero?
               (system* qemu "-nographic" "-no-reboot"
                        "-net" "nic,model=e1000"
                        "-net" (string-append "user,smb=" (getcwd))
                        "-kernel" linux
                        "-initrd" initrd
                        "-append" (string-append "console=ttyS0 --load="
                                                 builder)
                        ,@(if make-disk-image?
                              '("-hda" "image.qcow2")
                              '())))
              ,(if make-disk-image?
                   '(copy-file "image.qcow2"      ; XXX: who mkdir'd OUT?
                               out)
                   '(begin
                      (mkdir out)
                      (copy-recursively "xchg" out)))))))

  (mlet* %store-monad
      ((input-alist  (sequence %store-monad input-alist))
       (exp* ->      `(let ((%build-inputs ',input-alist))
                        ,exp))
       (user-builder (text-file "builder-in-linux-vm"
                                (object->string exp*)))
       (coreutils -> (car (assoc-ref %final-inputs "coreutils")))
       (inputs       (lower-inputs `(("qemu" ,qemu)
                                     ("linux" ,linux)
                                     ("initrd" ,initrd)
                                     ("coreutils" ,coreutils)
                                     ("builder" ,user-builder)
                                     ,@inputs))))
    (derivation-expression name builder
                           #:system system
                           #:inputs inputs
                           #:env-vars env-vars
                           #:modules (delete-duplicates
                                      `((guix build utils)
                                        ,@modules))
                           #:guile-for-build guile-for-build
                           #:references-graphs references-graphs)))

(define* (qemu-image #:key
                     (name "qemu-image")
                     (system (%current-system))
                     (disk-image-size (* 100 (expt 2 20)))
                     grub-configuration
                     (initialize-store? #f)
                     (populate #f)
                     (inputs '())
                     (inputs-to-copy '()))
  "Return a bootable, stand-alone QEMU image.  The returned image is a full
disk image, with a GRUB installation that uses GRUB-CONFIGURATION as its
configuration file.

INPUTS-TO-COPY is a list of inputs (as for packages) whose closure is copied
into the image being built.  When INITIALIZE-STORE? is true, initialize the
store database in the image so that Guix can be used in the image.

POPULATE is a list of directives stating directories or symlinks to be created
in the disk image partition.  It is evaluated once the image has been
populated with INPUTS-TO-COPY.  It can be used to provide additional files,
such as /etc files."
  (define (input->name+derivation tuple)
    (with-monad %store-monad
      (match tuple
        ((name (? package? package))
         (mlet %store-monad ((drv (package->derivation package system)))
           (return `(,name . ,(derivation->output-path drv)))))
        ((name (? package? package) sub-drv)
         (mlet %store-monad ((drv (package->derivation package system)))
           (return `(,name . ,(derivation->output-path drv sub-drv)))))
        ((name (? derivation? drv))
         (return `(,name . ,(derivation->output-path drv))))
        ((name (? derivation? drv) sub-drv)
         (return `(,name . ,(derivation->output-path drv sub-drv))))
        ((input (and (? string?) (? store-path?) file))
         (return `(,input . ,file))))))

  (mlet %store-monad
      ((graph (sequence %store-monad
                        (map input->name+derivation inputs-to-copy))))
   (expression->derivation-in-linux-vm
    "qemu-image"
    `(let ()
       (use-modules (ice-9 rdelim)
                    (srfi srfi-1)
                    (guix build utils)
                    (guix build linux-initrd))

       (let ((parted  (string-append (assoc-ref %build-inputs "parted")
                                     "/sbin/parted"))
             (mkfs    (string-append (assoc-ref %build-inputs "e2fsprogs")
                                     "/sbin/mkfs.ext3"))
             (grub    (string-append (assoc-ref %build-inputs "grub")
                                     "/sbin/grub-install"))
             (umount  (string-append (assoc-ref %build-inputs "util-linux")
                                     "/bin/umount")) ; XXX: add to Guile
             (grub.cfg (assoc-ref %build-inputs "grub.cfg")))

         (define (read-reference-graph port)
           ;; Return a list of store paths from the reference graph at PORT.
           ;; The data at PORT is the format produced by #:references-graphs.
           (let loop ((line   (read-line port))
                      (result '()))
             (cond ((eof-object? line)
                    (delete-duplicates result))
                   ((string-prefix? "/" line)
                    (loop (read-line port)
                          (cons line result)))
                   (else
                    (loop (read-line port)
                          result)))))

         (define (things-to-copy)
           ;; Return the list of store files to copy to the image.
           (define (graph-from-file file)
             (call-with-input-file file
               read-reference-graph))

           ,(match inputs-to-copy
              (((graph-files . _) ...)
               `(let* ((graph-files ',(map (cut string-append "/xchg/" <>)
                                           graph-files))
                       (paths       (append-map graph-from-file graph-files)))
                  (delete-duplicates paths)))
              (#f ''())))

         ;; GRUB is full of shell scripts.
         (setenv "PATH"
                 (string-append (dirname grub) ":"
                                (assoc-ref %build-inputs "coreutils") "/bin:"
                                (assoc-ref %build-inputs "findutils") "/bin:"
                                (assoc-ref %build-inputs "sed") "/bin:"
                                (assoc-ref %build-inputs "grep") "/bin:"
                                (assoc-ref %build-inputs "gawk") "/bin"))

         (display "creating partition table...\n")
         (and (zero? (system* parted "/dev/vda" "mklabel" "msdos"
                              "mkpart" "primary" "ext2" "1MiB"
                              ,(format #f "~aB"
                                       (- disk-image-size
                                          (* 5 (expt 2 20))))))
              (begin
                (display "creating ext3 partition...\n")
                (and (zero? (system* mkfs "-F" "/dev/vda1"))
                     (let ((store (string-append "/fs" ,%store-directory)))
                       (display "mounting partition...\n")
                       (mkdir "/fs")
                       (mount "/dev/vda1" "/fs" "ext3")
                       (mkdir-p "/fs/boot/grub")
                       (symlink grub.cfg "/fs/boot/grub/grub.cfg")

                       ;; Populate the image's store.
                       (mkdir-p store)
                       (chmod store #o1775)
                       (for-each (lambda (thing)
                                   (copy-recursively thing
                                                     (string-append "/fs"
                                                                    thing)))
                                 (cons grub.cfg (things-to-copy)))

                       ;; Populate /dev.
                       (make-essential-device-nodes #:root "/fs")

                       ;; Optionally, register the inputs in the image's store.
                       (let* ((guix     (assoc-ref %build-inputs "guix"))
                              (register (string-append guix
                                                       "/sbin/guix-register")))
                         ,@(if initialize-store?
                               (match inputs-to-copy
                                 (((graph-files . _) ...)
                                  (map (lambda (closure)
                                         `(system* register "--prefix" "/fs"
                                                   ,(string-append "/xchg/"
                                                                   closure)))
                                       graph-files)))
                               '(#f)))

                       ;; Evaluate the POPULATE directives.
                       ,@(let loop ((directives populate)
                                    (statements '()))
                           (match directives
                             (()
                              (reverse statements))
                             ((('directory name) rest ...)
                              (loop rest
                                    (cons `(mkdir-p ,(string-append "/fs" name))
                                          statements)))
                             ((('directory name uid gid) rest ...)
                              (let ((dir (string-append "/fs" name)))
                                (loop rest
                                      (cons* `(chown ,dir ,uid ,gid)
                                             `(mkdir-p ,dir)
                                             statements))))
                             (((new '-> old) rest ...)
                              (loop rest
                                    (cons `(symlink ,old
                                                    ,(string-append "/fs" new))
                                          statements)))))

                       (and=> (assoc-ref %build-inputs "populate")
                              (lambda (populate)
                                (chdir "/fs")
                                (primitive-load populate)
                                (chdir "/")))

                       (display "clearing file timestamps...\n")
                       (for-each (lambda (file)
                                   (let ((s (lstat file)))
                                     ;; XXX: Guile uses libc's 'utime' function
                                     ;; (not 'futime'), so the timestamp of
                                     ;; symlinks cannot be changed, and there
                                     ;; are symlinks here pointing to
                                     ;; /nix/store, which is the host,
                                     ;; read-only store.
                                     (unless (eq? (stat:type s) 'symlink)
                                       (utime file 0 0 0 0))))
                                 (find-files "/fs" ".*"))

                       (and (zero?
                             (system* grub "--no-floppy"
                                      "--boot-directory" "/fs/boot"
                                      "/dev/vda"))
                            (zero? (system* umount "/fs"))
                            (reboot))))))))
    #:system system
    #:inputs `(("parted" ,parted)
               ("grub" ,grub)
               ("e2fsprogs" ,e2fsprogs)
               ("grub.cfg" ,grub-configuration)

               ;; For shell scripts.
               ("sed" ,(car (assoc-ref %final-inputs "sed")))
               ("grep" ,(car (assoc-ref %final-inputs "grep")))
               ("coreutils" ,(car (assoc-ref %final-inputs "coreutils")))
               ("findutils" ,(car (assoc-ref %final-inputs "findutils")))
               ("gawk" ,(car (assoc-ref %final-inputs "gawk")))
               ("util-linux" ,util-linux)

               ,@(if initialize-store?
                     `(("guix" ,guix))
                     '())

               ,@inputs-to-copy)
    #:make-disk-image? #t
    #:disk-image-size disk-image-size
    #:references-graphs graph
    #:modules '((guix build utils)
                (guix build linux-initrd)))))


;;;
;;; Stand-alone VM image.
;;;

(define* (union inputs
                #:key (guile (%guile-for-build)) (system (%current-system))
                (name "union"))
  "Return a derivation that builds the union of INPUTS.  INPUTS is a list of
input tuples."
  (define builder
    '(begin
       (use-modules (guix build union))

       (setvbuf (current-output-port) _IOLBF)
       (setvbuf (current-error-port) _IOLBF)

       (let ((output (assoc-ref %outputs "out"))
             (inputs (map cdr %build-inputs)))
         (format #t "building union `~a' with ~a packages...~%"
                 output (length inputs))
         (union-build output inputs))))

  (mlet %store-monad
      ((inputs (sequence %store-monad
                         (map (match-lambda
                               ((name (? package? p))
                                (mlet %store-monad
                                    ((drv (package->derivation p system)))
                                  (return `(,name ,drv))))
                               ((name (? package? p) output)
                                (mlet %store-monad
                                    ((drv (package->derivation p system)))
                                  (return `(,name ,drv ,output))))
                               (x
                                (return x)))
                              inputs))))
    (derivation-expression name builder
                           #:system system
                           #:inputs inputs
                           #:modules '((guix build union))
                           #:guile-for-build guile)))

(define* (file-union files
                     #:key (inputs '()) (name "file-union"))
  "Return a derivation that builds a directory containing all of FILES.  Each
item in FILES must be a list where the first element is the file name to use
in the new directory, and the second element is the target file.

The subset of FILES corresponding to plain store files is automatically added
as an inputs; additional inputs, such as derivations, are taken from INPUTS."
  (mlet %store-monad ((inputs (lower-inputs inputs)))
    (let ((inputs (append inputs
                          (filter (match-lambda
                                   ((_ file)
                                    (direct-store-path? file)))
                                  files))))
      (derivation-expression name
                             `(let ((out (assoc-ref %outputs "out")))
                                (mkdir out)
                                (chdir out)
                                ,@(map (match-lambda
                                        ((name target)
                                         `(symlink ,target ,name)))
                                       files))

                             #:inputs inputs))))

(define* (etc-directory #:key
                        (accounts '())
                        (groups '())
                        (pam-services '())
                        (profile "/var/run/current-system/profile"))
  "Return a derivation that builds the static part of the /etc directory."
  (mlet* %store-monad
      ((services   (package-file net-base "etc/services"))
       (protocols  (package-file net-base "etc/protocols"))
       (rpc        (package-file net-base "etc/rpc"))
       (passwd     (passwd-file accounts))
       (shadow     (passwd-file accounts #:shadow? #t))
       (group      (group-file groups))
       (pam.d      (pam-services->directory pam-services))
       (login.defs (text-file "login.defs" "# Empty for now.\n"))
       (issue      (text-file "issue" "
This is an alpha preview of the GNU system.  Welcome.

This image features the GNU Guix package manager, which was used to
build it (http://www.gnu.org/software/guix/).  The init system is
GNU dmd (http://www.gnu.org/software/dmd/).

You can log in as 'guest' or 'root' with no password.
"))

       ;; TODO: Generate bashrc from packages' search-paths.
       (bashrc    (text-file "bashrc" (string-append "
export PS1='\\u@\\h\\$ '
export PATH=$HOME/.guix-profile/bin:" profile "/bin:" profile "/sbin
export CPATH=$HOME/.guix-profile/include:" profile "/include
export LIBRARY_PATH=$HOME/.guix-profile/lib:" profile "/lib
alias ls='ls -p --color'
alias ll='ls -l'
")))

       (files -> `(("services" ,services)
                   ("protocols" ,protocols)
                   ("rpc" ,rpc)
                   ("pam.d" ,(derivation->output-path pam.d))
                   ("login.defs" ,login.defs)
                   ("issue" ,issue)
                   ("profile" ,bashrc)
                   ("passwd" ,passwd)
                   ("shadow" ,shadow)
                   ("group" ,group))))
    (file-union files
                #:inputs `(("net" ,net-base)
                           ("pam.d" ,pam.d))
                #:name "etc")))

(define (system-qemu-image)
  "Return the derivation of a QEMU image of the GNU system."
  (mlet* %store-monad
      ((services (listm %store-monad
                        (host-name-service "gnu")
                        (mingetty-service "tty1")
                        (mingetty-service "tty2")
                        (mingetty-service "tty3")
                        (mingetty-service "tty4")
                        (mingetty-service "tty5")
                        (mingetty-service "tty6")
                        (syslog-service)
                        (guix-service)
                        (nscd-service)

                        ;; QEMU networking settings.
                        (static-networking-service "eth0" "10.0.2.10"
                                                   #:name-servers '("10.0.2.3")
                                                   #:gateway "10.0.2.2")))
       (motd     (text-file "motd" "
Happy birthday, GNU!                                http://www.gnu.org/gnu30

"))
       (pam-services ->
                     ;; Services known to PAM.
                     (list %pam-other-services
                           (unix-pam-service "login"
                                             #:allow-empty-passwords? #t
                                             #:motd motd)))

       (bash-file (package-file bash "bin/bash"))
       (dmd-file  (package-file dmd "bin/dmd"))
       (dmd-conf  (dmd-configuration-file services))
       (accounts -> (cons* (user-account
                            (name "root")
                            (password "")
                            (uid 0) (gid 0)
                            (comment "System administrator")
                            (home-directory "/")
                            (shell bash-file))
                           (user-account
                            (name "guest")
                            (password "")
                            (uid 1000) (gid 100)
                            (comment "Guest of GNU")
                            (home-directory "/home/guest")
                            (shell bash-file))
                           (append-map service-user-accounts
                                       services)))
       (groups   -> (cons* (user-group
                            (name "root")
                            (id 0))
                           (user-group
                            (name "users")
                            (id 100)
                            (members '("guest")))
                           (append-map service-user-groups services)))
       (build-user-gid -> (any (lambda (service)
                                 (and (equal? '(guix-daemon)
                                              (service-provision service))
                                      (match (service-user-groups service)
                                        ((group)
                                         (user-group-id group)))))
                               services))
       (packages -> `(("coreutils" ,coreutils)
                      ("bash" ,bash)
                      ("guile" ,guile-2.0)
                      ("dmd" ,dmd)
                      ("gcc" ,gcc-final)
                      ("libc" ,glibc-final)
                      ("inetutils" ,inetutils)
                      ("findutils" ,findutils)
                      ("grep" ,grep)
                      ("sed" ,sed)
                      ("procps" ,procps)
                      ("psmisc" ,psmisc)
                      ("zile" ,zile)
                      ("guix" ,guix)))

       ;; TODO: Replace with a real profile with a manifest.
       (profile-drv (union packages
                           #:name "default-profile"))
       (profile ->  (derivation->output-path profile-drv))
       (etc-drv     (etc-directory #:accounts accounts #:groups groups
                                   #:pam-services pam-services
                                   #:profile profile))
       (etc     ->  (derivation->output-path etc-drv))


       (populate -> `((directory "/nix/store" 0 ,build-user-gid)
                      (directory "/etc")
                      (directory "/var/log")      ; for dmd
                      (directory "/var/run/nscd")
                      ("/etc/static" -> ,etc)
                      ("/etc/shadow" -> "/etc/static/shadow")
                      ("/etc/passwd" -> "/etc/static/passwd")
                      ("/etc/group" -> "/etc/static/group")
                      ("/etc/login.defs" -> "/etc/static/login.defs")
                      ("/etc/pam.d" -> "/etc/static/pam.d")
                      ("/etc/profile" -> "/etc/static/profile")
                      ("/etc/issue" -> "/etc/static/issue")
                      ("/etc/services" -> "/etc/static/services")
                      ("/etc/protocols" -> "/etc/static/protocols")
                      ("/etc/rpc" -> "/etc/static/rpc")
                      (directory "/var/nix/gcroots")
                      ("/var/nix/gcroots/default-profile" -> ,profile)
                      ("/var/nix/gcroots/etc-directory" -> ,etc)
                      (directory "/tmp")
                      (directory "/var/nix/profiles/per-user/root" 0 0)
                      (directory "/var/nix/profiles/per-user/guest"
                                 1000 100)
                      (directory "/home/guest" 1000 100)))
       (boot     (text-file "boot" (object->string
                                    `(execl ,dmd-file "dmd"
                                            "--config" ,dmd-conf))))
       (entries -> (list (return (menu-entry
                                  (label (string-append
                                          "GNU system with Linux-Libre "
                                          (package-version linux-libre)
                                          " (technology preview)"))
                                  (linux linux-libre)
                                  (linux-arguments `("--root=/dev/vda1"
                                                     ,(string-append "--load=" boot)))
                                  (initrd gnu-system-initrd)))))
       (grub.cfg (grub-configuration-file entries)))
    (qemu-image  #:grub-configuration grub.cfg
                 #:populate populate
                 #:disk-image-size (* 550 (expt 2 20))
                 #:initialize-store? #t
                 #:inputs-to-copy `(("boot" ,boot)
                                    ("linux" ,linux-libre)
                                    ("initrd" ,gnu-system-initrd)
                                    ("dmd.conf" ,dmd-conf)
                                    ("profile" ,profile-drv)
                                    ("etc" ,etc-drv)
                                    ,@(append-map service-inputs
                                                  services)))))

;;; vm.scm ends here
