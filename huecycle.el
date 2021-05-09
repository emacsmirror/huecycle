;;; huecycle --- (TODO summary)                 -*- lexical-binding: t; -*-

;;; Commentary:

;;; TODO write me

;;; Code:

;; TODO checkdoc this file
;; TODO config to disable revertion when moving cursor
;; TODO deefcustom
;; clean up codes

(eval-when-compile (require 'cl-lib))

(defvar huecycle-step-size 0.01
  "Interval of time between color updates")

(defvar huecycle--interpolate-data '()
  "List of `huecycle-interpolate-datum'")

(defvar huecycle--idle-timer nil
  "Idle timer use")

(defvar huecycle--default-start-color "#888888"
  "Start color to use if a face has none, and none is specified")

(cl-defstruct (huecycle--color (:constructor huecycle--color-create)
                               (:copier nil))
  hue saturation luminance)

(cl-defstruct (huecycle--interp-datum (:constructor huecycle--interp-datum-create)
                                 (:copier nil))
  "Struct holds all data for one color interpolating face"
  (face nil :documentation "Affected face")
  (spec nil :documentation "Spec of face that is affected (should be `foreground', `background',
                                 `distant-foreground', or `distant-background')")
  (default-start-color nil :documentation "Start color to use over the faces spec")
  (start-color nil :documentation "Start color interpolated")
  (end-color nil :documentation "End color interpolated")
  (progress 0.0 :documentation "Current interpolation progress")
  (interp-func #'huecycle-interpolate-linear :documentation "Function used to interpolate values")
  (next-color-func #'huecycle-get-random-hsl-color :documentation "Function used to determine next color")
  (color-list '() :documentation "List of `huecycle--hsl-color' used by next-color-func")
  (random-color-hue-range '(0.0 1.0) :documentation "Range of hues that are randomly sampled in `huecycle-get-random-hsl-color'")
  (random-color-saturation-range '(0.5 1.0) :documentation "Range of saturation that are randomly sampled in `huecycle-get-random-hsl-color'")
  (random-color-luminance-range '(0.2 0.3) :documentation "Range of luminance that are randomly sampled in `huecycle-get-random-hsl-color'")
  (color-list-index 0 :documentation "Index used in next-color-func")
  (cookies '() :documentation "List of cookies generated by `face-remap-add-relative'")
  (step-multiple 1.0 :documentation "Multiplier on how much to modify speed of interpolation"))

(defun huecycle--init-interp-datum (face spec &rest rest)
  (cl-assert (facep face) "FACE isn't a valid face")
  (cl-assert (or (eq spec 'foreground) (eq spec 'background) (eq spec 'distant-foreground) (eq spec 'distant-background))
          "spec needs to refer to a color")
  (let (
        (interp-func (plist-get rest :interp-func))
        (next-color-func (plist-get rest :next-color-func))
        (start-color (plist-get rest :start-color))
        (color-list (plist-get rest :color-list))
        (step-multiple (plist-get rest :multiple))
        (random-color-hue-range (plist-get rest :random-color-hue-range))
        (random-color-saturation-range (plist-get rest :random-color-saturation-range))
        (random-color-luminance-range (plist-get rest :random-color-luminance-range)))
  (huecycle--interp-datum-create
   :face face
   :spec spec
   :interp-func (if interp-func interp-func #'huecycle-interpolate-linear)
   :default-start-color start-color
   :next-color-func (if next-color-func next-color-func #'huecycle-get-random-hsl-color)
   :color-list (if color-list (mapcar #'huecycle--hex-to-hsl-color color-list) '())
   :step-multiple (if step-multiple step-multiple 1.0)
   :random-color-hue-range (if random-color-hue-range random-color-hue-range '(0.0 1.0))
   :random-color-saturation-range (if random-color-saturation-range random-color-saturation-range '(0.5 1.0))
   :random-color-luminance-range (if random-color-luminance-range random-color-luminance-range '(0.2 0.3)))))

(defun huecycle--hex-to-rgb (hex)
  "Converts hex string (2 digits per component) to rgb tuple"
  (cl-assert (length= hex 7) "hex string should have 2 digits per component")
  (let (
        (red
         (/ (string-to-number (substring hex 1 3) 16) 255.0))
        (green
         (/ (string-to-number (substring hex 3 5) 16) 255.0))
        (blue
         (/ (string-to-number (substring hex 5 7) 16) 255.0)))
    (list red green blue)))

(defun huecycle--hex-to-hsl-color (color)
  "Converts hex string `color' to a `huecycle--color'"
  (pcase (apply 'color-rgb-to-hsl (huecycle--hex-to-rgb color))
    (`(,hue ,sat ,lum) (huecycle--color-create :hue hue :saturation sat :luminance lum))
    (`(,_) error "Could not parse hl-line")))

(defun huecycle--get-start-color (interp-datum)
  "Returns the current background color of the hl-line as `huecycle--color'"
  (let* (
         (face (huecycle--interp-datum-face interp-datum))
         (spec (huecycle--interp-datum-spec interp-datum))
         (start-color (huecycle--interp-datum-default-start-color interp-datum))
         (attribute
          (cond
           (start-color start-color)
           ((eq spec 'foreground) (face-attribute face :foreground))
           ((eq spec 'background) (face-attribute face :background))
           ((eq spec 'distant-foreground) (face-attribute face :distant-foreground))
           ((eq spec 'distant-background) (face-attribute face :distant-background))
           (t 'unspecified)))
         (attribute-color (if (eq attribute 'unspecified) huecycle--default-start-color attribute))
         (hsl (apply #'color-rgb-to-hsl (huecycle--hex-to-rgb attribute-color))))
    (pcase hsl
      (`(,hue ,sat ,lum) (huecycle--color-create :hue hue :saturation sat :luminance lum))
      (`(,_) error "Could not parse color"))))


(defun huecycle-get-random-hsl-color (interp-datum)
  "Returns random `hl-line-hsl-color'"
  (let (
        (hue-range (huecycle--interp-datum-random-color-hue-range interp-datum))
        (sat-range (huecycle--interp-datum-random-color-saturation-range interp-datum))
        (lum-range (huecycle--interp-datum-random-color-luminance-range interp-datum)))
  (huecycle--color-create
   :hue (huecycle--get-random-float-from (nth 0 hue-range) (nth 1 hue-range))
   :saturation (huecycle--get-random-float-from (nth 0 sat-range) (nth 1 sat-range))
   :luminance (huecycle--get-random-float-from (nth 0 lum-range) (nth 1 lum-range)))))

(defun huecycle--get-random-float-from (lower upper)
  "Gets random float from in range [lower, upper].
`lower' and `upper' should be in range [0.0, 1.0]"
  (cl-assert (and (>= lower 0.0) (<= lower 1.0)) "lower is not in range [0, 1]")
  (cl-assert (and (>= upper 0.0) (<= upper 1.0)) "upper is not in range [0, 1]")
  (cl-assert (<= lower upper) "lower should be <= upper")
  (if (= lower upper)
      (lower)
    (let* (
           (high-number 10000000000)
           (lower-int (truncate (* lower high-number)))
           (upper-int (truncate (* upper high-number))))
      (/ (* 1.0 (+ lower-int (random (- upper-int lower-int)))) high-number))))

;; TODO fix gthis and its other sim function
(defun huecycle-get-next-hsl-color (interp-datum)
  (let (
        (color-list (huecycle--interp-datum-color-list interp-datum))
        (color-list-index (huecycle--interp-datum-color-list-index interp-datum)))
    (if (= (length color-list) 0)
       nil
      (setf (huecycle--interp-datum-color-list-index interp-datum)
            (mod (1+ color-list-index) (length color-list)))
      (nth (huecycle--interp-datum-color-list-index interp-datum) color-list))))

(defun huecycle-get-random-hsl-color-from-list (interp-datum)
  (let (
        (color-list (huecycle--interp-datum-color-list interp-datum)))
    (if (length= (huecycle--interp-datum-color-list interp-datum) 0)
       nil
      (setf (huecycle--interp-datum-color-list-index interp-datum)
            (random (length color-list)))
      (nth color-list (huecycle--interp-datum-color-list-index interp-datum)))))

(defun huecycle--clamp (value low high)
  "Clamps `value' between `low' and `high'"
  (max (min value high) low))

(defun huecycle-interpolate-linear (progress start end)
  "Returns new color that is the result of interplating the colors of `start' and `end' linearly.
`progress' is a float in the range [0, 1], but providing a value outside of that will extrapolate new values.
`start' and `end' are `huecycle--color'"
  (let (
        (new-hue
         (huecycle--clamp
          (+ (* (- 1 progress) (huecycle--color-hue start)) (* progress (huecycle--color-hue end))) 0 1))
        (new-sat
         (huecycle--clamp
          (+ (* (- 1 progress) (huecycle--color-saturation start)) (* progress (huecycle--color-saturation end))) 0 1))
        (new-lum
         (huecycle--clamp
          (+ (* (- 1 progress) (huecycle--color-luminance start)) (* progress (huecycle--color-luminance end))) 0 1)))
    (huecycle--color-create :hue new-hue :saturation new-sat :luminance new-lum)))

(defun huecycle--hsl-color-to-hex (hsl-color)
  "Converts `huecycle--color' to hex string with 2 digits for each component"
  (let ((rgb (color-hsl-to-rgb
              (huecycle--color-hue hsl-color)
              (huecycle--color-saturation hsl-color)
              (huecycle--color-luminance hsl-color))))
    (color-rgb-to-hex (nth 0 rgb) (nth 1 rgb) (nth 2 rgb) 2)))

(defun huecycle--update-progress (new-progress interp-datum)
  (let (
        (progress (huecycle--interp-datum-progress interp-datum))
        (multiple (huecycle--interp-datum-step-multiple interp-datum)))
    (setq progress (+ progress (* new-progress multiple)))
    (if (>= progress 1.0)
        (progn
          (setq progress 0.0)
          (huecycle--change-next-colors interp-datum)))
    (setf (huecycle--interp-datum-progress interp-datum) progress)))


(defun huecycle--reset-faces (interp-datum)
  (let
       (cookies (huecycle--interp-datum-cookies interp-datum))
    (dolist (cookie cookies)
      (face-remap-remove-relative cookie))
    (setf (huecycle--interp-datum-cookies interp-datum) '())))

(defun huecycle--set-faces (interp-datum)
  (let* (
         (face (huecycle--interp-datum-face interp-datum))
         (spec (huecycle--interp-datum-spec interp-datum))
         (interp-func (huecycle--interp-datum-interp-func interp-datum))
         (start-color (huecycle--interp-datum-start-color interp-datum))
         (end-color (huecycle--interp-datum-end-color interp-datum))
         (progress (huecycle--interp-datum-progress interp-datum))
         (new-color
          (huecycle--hsl-color-to-hex
           (funcall interp-func progress start-color end-color))))
    (if (eq 'background spec)
        (progn
          (setf (huecycle--interp-datum-cookies interp-datum)
                (push (face-remap-add-relative face :background new-color)
                      (huecycle--interp-datum-cookies interp-datum)))))
    (if (eq 'foreground spec)
        (progn
          (setf (huecycle--interp-datum-cookies interp-datum)
                (push (face-remap-add-relative face :foreground new-color)
                      (huecycle--interp-datum-cookies interp-datum)))))
    (if (eq 'distant-foreground spec)
        (progn
          (setf (huecycle--interp-datum-cookies interp-datum)
                (push (face-remap-add-relative face :distant-foreground new-color)
                      (huecycle--interp-datum-cookies interp-datum)))))
    (if (eq 'distant-background spec)
        (progn
          (setf (huecycle--interp-datum-cookies interp-datum)
                (push (face-remap-add-relative face :distant-background new-color)
                      (huecycle--interp-datum-cookies interp-datum)))))
    (face-spec-recalc face (selected-frame))))

(defun huecycle--init-colors (interp-datum)
  (let ((next-color-func (huecycle--interp-datum-next-color-func interp-datum)))
    (setf (huecycle--interp-datum-start-color interp-datum)
          (huecycle--get-start-color interp-datum))
    (setf (huecycle--interp-datum-end-color interp-datum)
          (funcall next-color-func interp-datum))
    (setf (huecycle--interp-datum-progress interp-datum)
          0.0)))

(defun huecycle--change-next-colors (interp-datum)
  (let (
        (end-color (huecycle--interp-datum-end-color interp-datum))
        (next-color-func (huecycle--interp-datum-next-color-func interp-datum)))
    (setf (huecycle--interp-datum-start-color interp-datum) end-color)
    (setf (huecycle--interp-datum-end-color interp-datum)
          (funcall next-color-func interp-datum))))

;;;###autoload
(defun huecycle ()
  "Begin colorizing"
  (interactive)
  (mapc #'huecycle--init-colors huecycle--interpolate-data)
  (while (not (input-pending-p))
    (sit-for huecycle-step-size)
    (dolist (datum huecycle--interpolate-data)
      (huecycle--update-progress huecycle-step-size datum)
      (huecycle--reset-faces datum)
      (huecycle--set-faces datum)))
  (mapc #'huecycle--reset-faces huecycle--interpolate-data))

;;;###autoload
(defun huecycle-stop-idle ()
  "Stops the colorization effect when idle"
  (interactive)
  (if huecycle--idle-timer
      (cancel-timer huecycle--idle-timer))
  (setq huecycle--idle-timer nil))

;;;###autoload
(defun huecycle-when-idle (secs)
  "Starts the colorization effect. when idle for `secs' seconds"
  (huecycle-stop-idle)
  (setq huecycle--idle-timer (run-with-idle-timer secs t 'huecycle)))

(defmacro huecycle-set-faces (&rest faces)
  "Sets the faces to be used for color interpolation TODO improve this with in depth of all options"
  `(setq huecycle--interpolate-data (mapcar (apply-partially #'apply #'huecycle--init-interp-datum) ',faces)))

(provide 'huecycle)

;;; huecycle.el ends here
