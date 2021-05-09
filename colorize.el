;;; colorize --- (TODO summary)                 -*- lexical-binding: t; -*-

;;; Commentary:

;;; TODO write me

;;; Code:

;; TODO checkdoc this file
;; TODO config to disable revertion when moving cursor
;; TODO deefcustom
;; clean up codes
;; DONE rename package to "colorize" (or something to do with lerping colors over time idly)
;; TODO macro has no quotes at all for anything... little wierd

(eval-when-compile (require 'cl-lib))

(defvar colorize-step-size 0.01
  "Interval of time between color updates")

(defvar colorize--interpolate-data '()
  "List of `colorize-interpolate-datum'")

(defvar colorize--idle-timer nil
  "Idle timer use")

(defvar colorize--default-start-color "#888888"
  "Start color to use if a face has none, and none is specified")

(cl-defstruct (colorize--color (:constructor colorize--color-create)
                               (:copier nil))
  hue saturation luminance)

(cl-defstruct (colorize--interp-datum (:constructor colorize--interp-datum-create)
                                 (:copier nil))
  "Struct holds all data for one color interpolating face"
  (face nil :documentation "Affected face")
  (spec nil :documentation "Spec of face that is affected (should be `foreground', `background',
                                 `distant-foreground', or `distant-background')")
  (default-start-color nil :documentation "Start color to use over the faces spec")
  (start-color nil :documentation "Start color interpolated")
  (end-color nil :documentation "End color interpolated")
  (progress 0.0 :documentation "Current interpolation progress")
  (interp-func #'colorize-interpolate-linear :documentation "Function used to interpolate values")
  (next-color-func #'colorize-get-random-hsl-color :documentation "Function used to determine next color")
  (color-list '() :documentation "List of `colorize--hsl-color' used by next-color-func")
  (random-color-hue-range '(0.0 1.0) :documentation "Range of hues that are randomly sampled in `colorize-get-random-hsl-color'")
  (random-color-saturation-range '(0.5 1.0) :documentation "Range of saturation that are randomly sampled in `colorize-get-random-hsl-color'")
  (random-color-luminance-range '(0.2 0.3) :documentation "Range of luminance that are randomly sampled in `colorize-get-random-hsl-color'")
  (color-list-index 0 :documentation "Index used in next-color-func")
  (cookies '() :documentation "List of cookies generated by `face-remap-add-relative'")
  (step-multiple 1.0 :documentation "Multiplier on how much to modify speed of interpolation"))

(defun colorize--init-interp-datum (face spec &rest rest)
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
    (print start-color))
  (colorize--interp-datum-create
   :face face
   :spec spec
   :interp-func (if interp-func interp-func #'colorize-interpolate-linear)
   :default-start-color start-color
   :next-color-func (if next-color-func next-color-func #'colorize-get-random-hsl-color)
   :color-list (if color-list (mapcar #'colorize--hex-to-hsl-color color-list) '())
   :step-multiple (if step-multiple step-multiple 1.0)
   :random-color-hue-range (if random-color-hue-range random-color-hue-range '(0.0 1.0))
   :random-color-saturation-range (if random-color-saturation-range random-color-saturation-range '(0.5 1.0))
   :random-color-luminance-range (if random-color-luminance-range random-color-luminance-range '(0.2 0.3))))

(defun colorize--hex-to-rgb (hex)
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

(defun colorize--hex-to-hsl-color (color)
  "Converts hex string `color' to a `colorize--color'"
  (pcase (apply 'color-rgb-to-hsl (colorize--hex-to-rgb color))
    (`(,hue ,sat ,lum) (colorize--color-create :hue hue :saturation sat :luminance lum))
    (`(,_) error "Could not parse hl-line")))

(defun colorize--get-start-color (interp-datum)
  "Returns the current background color of the hl-line as `colorize--color'"
  (let* (
         (face (colorize--interp-datum-face interp-datum))
         (spec (colorize--interp-datum-spec interp-datum))
         (start-color (colorize--interp-datum-default-start-color interp-datum))
         (attribute
          (cond
           (start-color start-color)
           ((eq spec 'foreground) (face-attribute face :foreground))
           ((eq spec 'background) (face-attribute face :background))
           ((eq spec 'distant-foreground) (face-attribute face :distant-foreground))
           ((eq spec 'distant-background) (face-attribute face :distant-background))
           (t 'unspecified)))
         (attribute-color (if (eq attribute 'unspecified) colorize--default-start-color attribute))
         (hsl (apply #'color-rgb-to-hsl (colorize--hex-to-rgb attribute-color))))
    (pcase hsl
      (`(,hue ,sat ,lum) (colorize--color-create :hue hue :saturation sat :luminance lum))
      (`(,_) error "Could not parse color"))))


(defun colorize-get-random-hsl-color (interp-datum)
  "Returns random `hl-line-hsl-color'"
  (let (
        (hue-range (colorize--interp-datum-random-color-hue-range interp-datum))
        (sat-range (colorize--interp-datum-random-color-saturation-range interp-datum))
        (lum-range (colorize--interp-datum-random-color-luminance-range interp-datum))))
  (colorize--color-create
   :hue (colorize--get-random-float-from (nth 0 hue-range) (nth 1 hue-range))
   :saturation (colorize--get-random-float-from (nth 0 sat-range) (nth 1 sat-range))
   :luminance (colorize--get-random-float-from (nth 0 lum-range) (nth 1 lum-range))))

(defun colorize--get-random-float-from (lower upper)
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
(defun colorize-get-next-hsl-color (interp-datum)
  (let (
        (color-list (colorize--interp-datum-color-list interp-datum))
        (color-list-index (colorize--interp-datum-color-list-index interp-datum)))
    (if (= (length color-list) 0)
       nil
      (setf (colorize--interp-datum-color-list-index interp-datum)
            (mod (1+ color-list-index) (length color-list)))
      (nth (colorize--interp-datum-color-list-index interp-datum) color-list))))

(defun colorize-get-random-hsl-color-from-list (interp-datum)
  (let (
        (color-list (colorize--interp-datum-color-list interp-datum)))
    (if (length= (colorize--interp-datum-color-list interp-datum) 0)
       nil
      (setf (colorize--interp-datum-color-list-index interp-datum)
            (random (length color-list)))
      (nth color-list (colorize--interp-datum-color-list-index interp-datum)))))

(defun colorize--clamp (value low high)
  "Clamps `value' between `low' and `high'"
  (max (min value high) low))

(defun colorize-interpolate-linear (progress start end)
  "Returns new color that is the result of interplating the colors of `start' and `end' linearly.
`progress' is a float in the range [0, 1], but providing a value outside of that will extrapolate new values.
`start' and `end' are `colorize--color'"
  (let (
        (new-hue
         (colorize--clamp
          (+ (* (- 1 progress) (colorize--color-hue start)) (* progress (colorize--color-hue end))) 0 1))
        (new-sat
         (colorize--clamp
          (+ (* (- 1 progress) (colorize--color-saturation start)) (* progress (colorize--color-saturation end))) 0 1))
        (new-lum
         (colorize--clamp
          (+ (* (- 1 progress) (colorize--color-luminance start)) (* progress (colorize--color-luminance end))) 0 1)))
    (colorize--color-create :hue new-hue :saturation new-sat :luminance new-lum)))

(defun colorize--hsl-color-to-hex (hsl-color)
  "Converts `colorize--color' to hex string with 2 digits for each component"
  (let ((rgb (color-hsl-to-rgb
              (colorize--color-hue hsl-color)
              (colorize--color-saturation hsl-color)
              (colorize--color-luminance hsl-color))))
    (color-rgb-to-hex (nth 0 rgb) (nth 1 rgb) (nth 2 rgb) 2)))

(defun colorize--update-progress (new-progress interp-datum)
  (let (
        (progress (colorize--interp-datum-progress interp-datum))
        (multiple (colorize--interp-datum-step-multiple interp-datum)))
    (setq progress (+ progress (* new-progress multiple)))
    (if (>= progress 1.0)
        (progn
          (setq progress 0.0)
          (colorize--change-next-colors interp-datum)))
    (setf (colorize--interp-datum-progress interp-datum) progress)))


(defun colorize--reset-faces (interp-datum)
  (let ()
       (cookies (colorize--interp-datum-cookies interp-datum))
    (dolist (cookie cookies)
      (face-remap-remove-relative cookie))
    (setf (colorize--interp-datum-cookies interp-datum) '())))

(defun colorize--set-faces (interp-datum)
  (let* (
         (face (colorize--interp-datum-face interp-datum))
         (spec (colorize--interp-datum-spec interp-datum))
         (interp-func (colorize--interp-datum-interp-func interp-datum))
         (start-color (colorize--interp-datum-start-color interp-datum))
         (end-color (colorize--interp-datum-end-color interp-datum))
         (progress (colorize--interp-datum-progress interp-datum))
         (new-color
          (colorize--hsl-color-to-hex
           (funcall interp-func progress start-color end-color))))
    (if (eq 'background spec)
        (progn
          (setf (colorize--interp-datum-cookies interp-datum)
                (push (face-remap-add-relative face :background new-color)
                      (colorize--interp-datum-cookies interp-datum)))))
    (if (eq 'foreground spec)
        (progn
          (setf (colorize--interp-datum-cookies interp-datum)
                (push (face-remap-add-relative face :foreground new-color)
                      (colorize--interp-datum-cookies interp-datum)))))
    (if (eq 'distant-foreground spec)
        (progn
          (setf (colorize--interp-datum-cookies interp-datum)
                (push (face-remap-add-relative face :distant-foreground new-color)
                      (colorize--interp-datum-cookies interp-datum)))))
    (if (eq 'distant-background spec)
        (progn
          (setf (colorize--interp-datum-cookies interp-datum)
                (push (face-remap-add-relative face :distant-background new-color)
                      (colorize--interp-datum-cookies interp-datum)))))
    (face-spec-recalc face (selected-frame))))

(defun colorize--init-colors (interp-datum)
  (let ((next-color-func (colorize--interp-datum-next-color-func interp-datum)))
    (setf (colorize--interp-datum-start-color interp-datum)
          (colorize--get-start-color interp-datum))
    (setf (colorize--interp-datum-end-color interp-datum)
          (funcall next-color-func interp-datum))
    (setf (colorize--interp-datum-progress interp-datum)
          0.0)))

(defun colorize--change-next-colors (interp-datum)
  (let (
        (end-color (colorize--interp-datum-end-color interp-datum))
        (next-color-func (colorize--interp-datum-next-color-func interp-datum)))
    (setf (colorize--interp-datum-start-color interp-datum) end-color)
    (setf (colorize--interp-datum-end-color interp-datum)
          (funcall next-color-func interp-datum))))

;;;###autoload
(defun colorize ()
  "Begin colorizing"
  (interactive)
  (mapc #'colorize--init-colors colorize--interpolate-data)
  (while (not (input-pending-p))
    (sit-for colorize-step-size)
    (dolist (datum colorize--interpolate-data)
      (colorize--update-progress colorize-step-size datum)
      (colorize--reset-faces datum)
      (colorize--set-faces datum)))
  (mapc #'colorize--reset-faces colorize--interpolate-data))

;;;###autoload
(defun colorize-stop-idle ()
  "Stops the colorization effect when idle"
  (interactive)
  (if colorize--idle-timer
      (cancel-timer colorize--idle-timer))
  (setq colorize--idle-timer nil))

;;;###autoload
(defun colorize-when-idle (secs)
  "Starts the colorization effect. when idle for `secs' seconds"
  (colorize-stop-idle)
  (setq colorize--idle-timer (run-with-idle-timer secs t 'colorize)))

(defmacro colorize-set-faces (&rest faces)
  "Sets the faces to be used for color interpolation TODO improve this with in depth of all options"
  `(setq colorize--interpolate-data (mapcar (apply-partially #'apply #'colorize--init-interp-datum) ',faces)))

(provide 'colorize)

;;; colorize.el ends here
